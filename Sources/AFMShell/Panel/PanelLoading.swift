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
internal final class PanelLoading: Sendable {
    /// What is read, and with what: the same for a reading in pieces and one in one go.
    internal struct Source: Sendable {
        /// The location to read.
        internal let location: URL
        /// Whether hidden entries are listed.
        internal let showHidden: Bool
        /// The file systems that read it.
        internal let fileSystems: FileSystemRegistry
        /// Where a complete reading is remembered.
        internal let cache: ListingCache
    }

    /// One piece of a reading: the whole list so far, ready to show.
    internal struct Piece {
        /// The directory and its surroundings; `items` is everything read so far, sorted by `order`.
        internal let listing: Listing
        /// The item the cursor should go to, when the location named a file.
        internal let focus: String?
        /// The order the items are in.
        internal let order: ListOrder
        /// Whether this is the first piece, which replaces what the panel showed.
        internal let isFirst: Bool
        /// Whether this is the last piece.
        internal let isLast: Bool
    }

    /// A location that was read to its end: the listing's items are sorted by `order`.
    internal struct Whole {
        /// The directory and its items.
        internal let listing: Listing
        /// The item the cursor should go to, when the location named a file.
        internal let focus: String?
        /// The order the items are in.
        internal let order: ListOrder
    }

    /// The order the list should come in, which the panel may change while the reading is under way
    /// (the user sorts a listing that is still arriving).
    ///
    /// Safe to use from any thread: the order is guarded by `lock`.
    internal final class OrderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var order: ListOrder

        /// The order, from any thread.
        internal var value: ListOrder {
            get { lock.withLock { order } }
            set { lock.withLock { order = newValue } }
        }

        /// A box holding `order`.
        internal init(_ order: ListOrder) {
            self.order = order
        }

        deinit {
            // Nothing to release.
        }
    }

    /// How long a read may take before the panel shows something: the first entries if there are
    /// any by then, otherwise the opened but still empty folder.
    ///
    /// Short enough to feel immediate, long enough that an ordinary folder appears whole, without a
    /// flash of emptiness.
    internal static let firstPieceDelay: TimeInterval = 0.1
    /// How long a read may deliver nothing at all before the panel enters the folder empty.
    ///
    /// Longer than `firstPieceDelay`, so a folder that takes a little over that shows its first
    /// entries and not an empty list for a blink before them.
    internal static let emptyOpenDelay: TimeInterval = 0.25
    /// The first piece is kept small, so it is sorted and on screen at once.
    internal static let firstPieceLimit = 5_000
    /// The pause before the second piece; each later pause is longer by `intervalGrowth`, so a
    /// very long listing does not keep the list jumping.
    internal static let secondPieceInterval: TimeInterval = 0.3
    /// How much longer each pause between pieces is than the one before.
    internal static let intervalGrowth = 1.5

    private let source: Source
    private let order: OrderBox
    private let cancellation: CancellationFlag

    /// A reading of `source` that follows `order` and stops when `cancellation` is set.
    internal init(_ source: Source, order: OrderBox, cancellation: CancellationFlag) {
        self.source = source
        self.order = order
        self.cancellation = cancellation
    }

    /// Reads a location completely, sorts it (on all cores when it is large) and hands it to the
    /// cache.
    ///
    /// Blocks for as long as the file system needs: **for a background thread**. With `climbing`, a
    /// folder that is gone is replaced by its nearest parent that can be read. Returns nil when
    /// `cancellation` was set before the end; nothing is remembered then, because a reading that
    /// was stopped may be incomplete.
    ///
    /// `progress` is called on the reading thread with the number of entries so far, each
    /// time more have arrived; returning false stops the reading as `cancellation` does.
    internal static func readWhole(
        _ source: Source,
        order: ListOrder,
        climbing: Bool,
        cancellation: CancellationFlag,
        progress: ((Int) -> Bool)?
    ) throws -> Whole? {
        let (started, ticket) = (Date(), source.cache.startReading())
        var items: [FileItem] = []
        var header: PanelLoader.Batch?
        func receive(_ batch: PanelLoader.Batch) -> Bool {
            if header == nil {
                header = batch
            }
            items += batch.listing.items
            if let progress, !progress(items.count) {
                cancellation.cancel()
            }
            return !cancellation.isCancelled
        }
        let (location, showHidden, fileSystems) = (source.location, source.showHidden, source.fileSystems)
        if climbing {
            try PanelLoader.stream(
                climbingFrom: location,
                showHidden: showHidden,
                fileSystems: fileSystems,
                cancellation: cancellation,
                receive: receive
            )
        } else {
            try PanelLoader.stream(
                location,
                showHidden: showHidden,
                fileSystems: fileSystems,
                cancellation: cancellation,
                receive: receive
            )
        }
        guard !cancellation.isCancelled, let header else {
            return nil
        }
        let listing = header.listing.with(items: Sorter.sort(items, by: order))
        let readTime = Date().timeIntervalSince(started)
        source.cache.store(listing, sortedBy: order, showHidden: showHidden, readTime: readTime, since: ticket)
        return Whole(listing: listing, focus: header.focus, order: order)
    }

    /// Both callbacks are called on the main thread, from the run loop (`MainLoop`): `onPiece` for
    /// each piece in order (not after cancellation), then `onEnd` once, with the error if the read
    /// failed.
    ///
    /// The reading runs in the lane of its location (`Background`: one of the kernel's threads for
    /// calls that block, never a dispatch queue's), behind any reading of the same location that
    /// has not come back yet; a reading that is overtaken returns at once, whatever its file system
    /// is doing (`PanelLoader.stream`). The callbacks, which hold the panel, stay with the main
    /// thread and are let go of there.
    internal func start(onPiece: @escaping (Piece) -> Void, onEnd: @escaping (any Error?) -> Void) {
        let (source, order, cancellation) = (source, order, cancellation)
        let receivers = MainOwned(PanelPieceStream.Receivers(onPiece: onPiece, onEnd: onEnd))
        Background.storage("list", at: source.location) {
            // Overtaken while it waited for its turn: the file system is not asked at all.
            guard !cancellation.isCancelled else {
                return MainLoop.perform { receivers.take()?.onEnd(nil) }
            }
            // Everything below belongs to this background thread.
            PanelPieceStream(source: source, order: order, cancellation: cancellation, receivers: receivers).run()
        }
    }
}
