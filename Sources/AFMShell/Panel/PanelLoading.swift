import AFMKernel
import Foundation

/// Reads one location for a panel on a background thread and hands it over in pieces.
///
/// A directory that is read quickly arrives as a single piece. One that takes longer (a huge
/// folder, a slow server) is shown after a moment with what has arrived, and grows while the
/// rest is read. All sorting and merging happens here in the background, on all cores when the
/// list is large; each piece carries the whole list so far, ready to show, so the main thread
/// only swaps one list for another.
///
/// A reading that reaches its end is also handed to the listing cache, from the background
/// thread (the cache is safe to use from any thread).
final class PanelLoading: Sendable {
    struct Piece {
        /// The directory and its surroundings; `items` is everything read so far, sorted by `order`.
        let listing: Listing
        let focus: String?
        let order: ListOrder
        let isFirst: Bool
        let isLast: Bool
    }

    /// How long a read may take before the panel shows something: the first entries if there
    /// are any by then, otherwise the opened but still empty folder. Short enough to feel
    /// immediate, long enough that an ordinary folder appears whole, without a flash of emptiness.
    static let firstPieceDelay: TimeInterval = 0.1
    /// How long a read may deliver nothing at all before the panel enters the folder empty.
    /// Longer than `firstPieceDelay`, so a folder that takes a little over that shows its first
    /// entries and not an empty list for a blink before them.
    static let emptyOpenDelay: TimeInterval = 0.25
    /// The first piece is kept small, so it is sorted and on screen at once.
    static let firstPieceLimit = 5_000
    /// The pause before the second piece; each later pause is longer by `intervalGrowth`, so a
    /// very long listing does not keep the list jumping.
    static let secondPieceInterval: TimeInterval = 0.3
    static let intervalGrowth = 1.5

    /// The order the list should come in, which the panel may change while the reading is under
    /// way (the user sorts a listing that is still arriving). Safe to use from any thread: the
    /// order is guarded by `lock`.
    final class OrderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var order: ListOrder

        init(_ order: ListOrder) {
            self.order = order
        }

        var value: ListOrder {
            get {
                lock.lock()
                defer { lock.unlock() }
                return order
            }
            set {
                lock.lock()
                order = newValue
                lock.unlock()
            }
        }
    }

    private let location: URL
    private let showHidden: Bool
    private let order: OrderBox
    private let fileSystems: FileSystemRegistry
    private let cache: ListingCache
    private let cancellation: CancellationFlag

    init(
        location: URL, showHidden: Bool, order: OrderBox, fileSystems: FileSystemRegistry, cache: ListingCache,
        cancellation: CancellationFlag
    ) {
        self.location = location
        self.showHidden = showHidden
        self.order = order
        self.fileSystems = fileSystems
        self.cache = cache
        self.cancellation = cancellation
    }

    convenience init(
        location: URL, showHidden: Bool, order: ListOrder, fileSystems: FileSystemRegistry, cache: ListingCache,
        cancellation: CancellationFlag
    ) {
        self.init(
            location: location, showHidden: showHidden, order: OrderBox(order), fileSystems: fileSystems, cache: cache,
            cancellation: cancellation)
    }

    /// A location that was read to its end: the listing's items are sorted by `order`.
    struct Whole {
        let listing: Listing
        let focus: String?
        let order: ListOrder
    }

    /// Reads a location completely, sorts it (on all cores when it is large) and hands it to
    /// the cache. Blocks for as long as the file system needs: **for a background thread**.
    /// Returns nil when `cancellation` was set before the end; nothing is remembered then,
    /// because a reading that was stopped may be incomplete.
    ///
    /// `progress` is called on the reading thread with the number of entries so far, each
    /// time more have arrived; returning false stops the reading as `cancellation` does.
    static func readWhole(
        _ location: URL, showHidden: Bool, order: ListOrder, fileSystems: FileSystemRegistry, cache: ListingCache,
        climbing: Bool = false, cancellation: CancellationFlag, progress: ((Int) -> Bool)? = nil
    ) throws -> Whole? {
        let (started, ticket) = (Date(), cache.startReading())
        var items: [FileItem] = []
        var header: PanelLoader.Batch?
        func receive(_ batch: PanelLoader.Batch) -> Bool {
            if header == nil { header = batch }
            items += batch.listing.items
            if let progress, !progress(items.count) { cancellation.cancel() }
            return !cancellation.isCancelled
        }
        if climbing {
            try PanelLoader.stream(
                climbingFrom: location, showHidden: showHidden, fileSystems: fileSystems, cancellation: cancellation,
                receive: receive)
        } else {
            try PanelLoader.stream(
                location, showHidden: showHidden, fileSystems: fileSystems, cancellation: cancellation,
                receive: receive)
        }
        guard !cancellation.isCancelled, let header else { return nil }
        let readTime = Date().timeIntervalSince(started)
        let listing = Listing(
            directory: header.listing.directory, items: Sorter.sort(items, by: order),
            parent: header.listing.parent, root: header.listing.root, volume: header.listing.volume)
        cache.store(listing, sortedBy: order, showHidden: showHidden, readTime: readTime, since: ticket)
        return Whole(listing: listing, focus: header.focus, order: order)
    }

    /// Both callbacks are called on the main thread, from the run loop (`MainLoop`): `onPiece`
    /// for each piece in order (not after cancellation), then `onEnd` once, with the error if
    /// the read failed. The reading runs in the lane of its location (`Background`: one of the
    /// kernel's threads for calls that block, never a dispatch queue's), behind any reading of
    /// the same location that has not come back yet; a reading that is overtaken returns at
    /// once, whatever its file system is doing (`PanelLoader.stream`). The callbacks, which hold
    /// the panel, stay with the main thread and are let go of there.
    func start(onPiece: @escaping (Piece) -> Void, onEnd: @escaping (any Error?) -> Void) {
        let (location, showHidden, order, fileSystems, cache, cancellation) = (
            location, showHidden, order, fileSystems, cache, cancellation
        )
        let receivers = MainOwned((onPiece: onPiece, onEnd: onEnd))
        Background.storage("list", at: location) {
            // Everything below belongs to this background thread.
            // Overtaken while it waited for its turn: the file system is not asked at all.
            guard !cancellation.isCancelled else {
                return MainLoop.perform { receivers.take()?.onEnd(nil) }
            }
            let (started, ticket) = (Date(), cache.startReading())
            var sorted = SortedFileList(order: order.value)
            var pending: [FileItem] = []
            var header: PanelLoader.Batch?
            var sentFirst = false
            var lastSent = Date()
            var interval = Self.firstPieceDelay

            @discardableResult
            func send(isLast: Bool) -> Piece? {
                guard let header else { return nil }
                // The list was put in another order meanwhile: what has arrived is sorted anew here,
                // in the background, so the panel never has to.
                let wanted = order.value
                if wanted != sorted.order {
                    var fresh = SortedFileList(order: wanted)
                    fresh.add(sorted.items)
                    sorted = fresh
                }
                if !sentFirst, !isLast, pending.count > Self.firstPieceLimit {
                    // Only a part goes into the first piece; the rest waits for the second.
                    sorted.add(Array(pending.prefix(Self.firstPieceLimit)))
                    pending.removeFirst(Self.firstPieceLimit)
                } else {
                    sorted.add(pending)
                    pending = []
                }
                let listing = Listing(
                    directory: header.listing.directory, items: sorted.items,
                    parent: header.listing.parent, root: header.listing.root, volume: header.listing.volume)
                let piece = Piece(
                    listing: listing, focus: header.focus, order: sorted.order, isFirst: !sentFirst, isLast: isLast)
                interval = sentFirst ? interval * Self.intervalGrowth : Self.secondPieceInterval
                sentFirst = true
                lastSent = Date()
                MainLoop.perform {
                    if !cancellation.isCancelled { receivers.held?.onPiece(piece) }
                }
                return piece
            }

            var failure: any Error?
            do {
                try PanelLoader.stream(
                    location, showHidden: showHidden, fileSystems: fileSystems, cancellation: cancellation
                ) { batch in
                    if header == nil { header = batch }
                    pending += batch.listing.items
                    if Date().timeIntervalSince(lastSent) > interval { send(isLast: false) }
                    return !cancellation.isCancelled
                }
            } catch {
                failure = error
            }
            let readTime = Date().timeIntervalSince(started)
            // A read that failed half-way still delivers what it had.
            if !cancellation.isCancelled, failure == nil || sentFirst {
                // Only a listing that arrived whole and without an error is remembered.
                if let piece = send(isLast: true), failure == nil {
                    cache.store(
                        piece.listing, sortedBy: piece.order, showHidden: showHidden, readTime: readTime, since: ticket
                    )
                }
            }
            MainLoop.perform { [failure] in receivers.take()?.onEnd(failure) }
        }
    }
}
