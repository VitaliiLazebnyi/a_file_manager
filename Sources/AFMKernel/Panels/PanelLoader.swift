public import Foundation

/// Reads what a panel is asked to show.
///
/// Everything here blocks on the file system and is meant for a background thread; the results are
/// applied to the model on the main thread.
public enum PanelLoader: Sendable {
    /// A location read completely.
    public struct Result: Sendable {
        /// The directory with all its entries.
        public let listing: Listing
        /// The item the cursor should go to, when the location named a file.
        public let focus: String?
    }

    /// One piece of a directory that is read step by step.
    public struct Batch: Sendable {
        /// The directory and its surroundings; `items` holds only the entries of this batch.
        public let listing: Listing
        /// The item the cursor should go to, when the location named a file.
        public let focus: String?
        /// The first batch replaces what the panel shows; later ones are added to it.
        public let isFirst: Bool
    }

    /// What is read, and what is done when it cannot be.
    private struct Request {
        /// The location asked for.
        let location: URL
        /// Whether hidden files are listed.
        let showHidden: Bool
        /// Whether the nearest readable parent is read when the location cannot be.
        let climbing: Bool
        /// Set when the reading is no longer wanted.
        let cancellation: CancellationFlag

        /// A request; without a flag of the caller's, the reading cannot be cancelled.
        init(climbing: Bool, location: URL, showHidden: Bool, cancellation: CancellationFlag?) {
            (self.climbing, self.location, self.showHidden) = (climbing, location, showHidden)
            self.cancellation = cancellation ?? CancellationFlag()
        }
    }

    /// One reading of a location: lists it, or what stands in for it when it cannot be read.
    private struct Reader {
        /// The file system of the location.
        let provider: any FileSystemProvider
        /// What is read.
        let request: Request
        /// Takes the batches; false when no more are wanted.
        let receive: (Batch) -> Bool
        /// Whether a batch was handed over.
        var delivered = false

        /// Reads the location; the location of a file leads to its folder, and with
        /// `climbing`, a folder that cannot be read to its nearest readable parent.
        mutating func read() throws {
            let location = request.location.standardized
            do {
                try list(location, focus: nil)
            } catch {
                guard !delivered, !request.cancellation.isCancelled else {
                    throw error
                }
                let item = ask(provider, "item " + location.locationKey, request.cancellation) { [provider] flag in
                    provider.item(at: location, cancellation: flag)
                }
                if let item, !item.isDirectory, let parent = provider.parent(of: location) {
                    try list(parent, focus: item.name)
                    return
                }
                guard request.climbing, !request.cancellation.isCancelled else {
                    throw error
                }
                try climb(from: location, error)
            }
        }

        /// Reads the nearest parent of `location` that can be read; throws `error` when none can.
        mutating func climb(from location: URL, _ error: any Error) throws {
            var current = location
            while let parent = provider.parent(of: current) {
                current = parent
                if (try? list(current, focus: nil)) != nil || delivered || request.cancellation.isCancelled {
                    return
                }
            }
            throw error
        }

        /// Lists a directory in batches; an empty one gives one empty batch.
        mutating func list(_ directory: URL, focus: String?) throws {
            let cancellation = request.cancellation
            let parent = provider.parent(of: directory)
            let root = roots.root(of: directory, parent: parent, in: provider)
            let volume = ask(provider, "volume " + directory.locationKey, cancellation) { [provider] flag in
                provider.volume(of: directory, cancellation: flag)
            }
            if cancellation.isCancelled {
                return
            }
            var delivered = self.delivered
            let take = receive
            func hand(_ items: [FileItem]) -> Bool {
                let listing = Listing(directory: directory, items: items, parent: parent, root: root, volume: volume)
                defer { delivered = true }
                return take(Batch(listing: listing, focus: focus, isFirst: !delivered))
            }
            defer { self.delivered = delivered }
            let wanted = { (items: [FileItem]) in !cancellation.isCancelled && hand(items) }
            try listing(
                of: directory,
                showHidden: request.showHidden,
                in: provider,
                cancellation: cancellation,
                receive: wanted
            )
            if !delivered, !cancellation.isCancelled { _ = hand([]) }
        }
    }

    /// Remembers the tops of the trees of the directories read a moment ago.
    private static let roots = RootCache()

    /// Reads a location completely.
    ///
    /// The location of a file leads to its folder, with the file as focus. With `climbing`, a
    /// folder that cannot be read is replaced by its nearest readable parent (a folder that
    /// vanished while the panel was showing it). Throws `CocoaError(.userCancelled)` when
    /// `cancellation` was set before the end: what had arrived by then is not a listing.
    public static func load(
        _ location: URL,
        showHidden: Bool,
        fileSystems: FileSystemRegistry,
        climbing: Bool = false,
        cancellation: CancellationFlag? = nil
    ) throws -> Result {
        var items: [FileItem] = []
        var first: Batch?
        let request = Request(
            climbing: climbing,
            location: location,
            showHidden: showHidden,
            cancellation: cancellation
        )
        let flag = request.cancellation
        try stream(request, fileSystems: fileSystems) { batch in
            if batch.isFirst { first = batch }
            items += batch.listing.items
            return true
        }
        // Nothing arrives only when the reading was cancelled.
        guard let first, !flag.isCancelled else {
            throw CocoaError(.userCancelled)
        }
        let header = first.listing
        let listing = Listing(
            directory: header.directory,
            items: items,
            parent: header.parent,
            root: header.root,
            volume: header.volume
        )
        return Result(listing: listing, focus: first.focus)
    }

    /// Reads a location piece by piece, so a large or slow directory can be shown while it is still
    /// arriving.
    ///
    /// `receive` gets at least one batch (an empty directory gives one empty batch) and returns
    /// false to stop. An error is thrown, also after batches have been delivered: what had arrived
    /// by then is not the whole directory, and the caller decides what to do with it. The location
    /// of a file leads to its folder, with the file as focus.
    ///
    /// `cancellation` is handed to the file system, so that a listing which waits (for a
    /// server) ends when the flag is set, and not only between two batches. The reading then
    /// stops where it is, quietly or with the file system's error; `receive` is not called
    /// again, perhaps never, and nothing else is tried. The caller looks at the flag.
    ///
    /// **A location that does not answer** (a share whose server is gone) costs the caller
    /// nothing but the wait, and that ends with the flag. Every question to the file system
    /// that can block (the volume, the listing, the entry at the location) is asked on a
    /// thread of the kernel's own (`BlockingCalls`), never on the calling thread, which may
    /// belong to a dispatch queue; `receive` is still called on the calling thread. The
    /// same question about the same location is not asked again while it is unanswered:
    /// the volume is asked once for all who want it, and a listing waits, without a thread,
    /// for an earlier listing of the location that was given up and has not come back.
    /// However often a dead location is tried, one thread is stuck in each question, not
    /// one per try.
    ///
    /// (Called on the main thread, which is for tests and small tools only, the questions
    /// are asked on the main thread itself as they always were: a file system that turns to
    /// the main thread while it answers, for a password, would otherwise wait for a thread
    /// that waits for it.)
    public static func stream(
        _ location: URL,
        showHidden: Bool,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag? = nil,
        receive: (Batch) -> Bool
    ) throws {
        let request = Request(climbing: false, location: location, showHidden: showHidden, cancellation: cancellation)
        try stream(request, fileSystems: fileSystems, receive: receive)
    }

    /// Reads a location piece by piece as `stream(_:showHidden:fileSystems:cancellation:receive:)`
    /// does, and when the location cannot be read, its nearest readable parent (a folder that
    /// vanished while the panel was showing it).
    public static func stream(
        climbingFrom location: URL,
        showHidden: Bool,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag? = nil,
        receive: (Batch) -> Bool
    ) throws {
        let request = Request(climbing: true, location: location, showHidden: showHidden, cancellation: cancellation)
        try stream(request, fileSystems: fileSystems, receive: receive)
    }

    /// Reads what `request` asks for.
    private static func stream(_ request: Request, fileSystems: FileSystemRegistry, receive: (Batch) -> Bool) throws {
        let provider = try fileSystems.provider(for: request.location)
        try withoutActuallyEscaping(receive) { receive in
            var reader = Reader(provider: provider, request: request, receive: receive)
            try reader.read()
        }
    }

    /// A question that may block, asked on a kernel thread and shared with whoever asks the
    /// same; nil when `cancellation` was set before the answer came.
    private static func ask<Answer: Sendable>(
        _ provider: any FileSystemProvider,
        _ question: String,
        _ cancellation: CancellationFlag,
        _ work: @escaping @Sendable (CancellationFlag) -> Answer?
    ) -> Answer? {
        if Thread.isMainThread {
            return work(cancellation)
        }
        return BlockingCalls.answer(from: provider, to: question, cancellation: cancellation, work).flatMap(\.self)
    }

    /// Lists a directory on a kernel thread and hands every batch to the calling thread, where
    /// `receive` runs as if the file system had called it; the caller has checked `cancellation`.
    ///
    /// Returns when the listing is over, when `receive` wanted no more, or, without a word, when
    /// `cancellation` is set; the file system's thread is then left to come back in its own time.
    private static func listing(
        of directory: URL,
        showHidden: Bool,
        in provider: any FileSystemProvider,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws {
        if Thread.isMainThread {
            try provider.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
            return
        }
        let relay = ListingRelay()
        let ticket = CallBook.shared.ask(
            owner: provider,
            question: "list \(showHidden ? "all" : "shown") " + directory.locationKey,
            shares: false,
            work: { flag -> Any in
                Swift.Result<Void, any Error> {
                    try provider.list(directory, showHidden: showHidden, cancellation: flag) { relay.offer($0) }
                }
            },
            listener: { relay.finish($0 as? Swift.Result<Void, any Error>) }
        )
        let registration = cancellation.onCancel {
            ticket.cancel()
            relay.abandon()
        }
        // The registration is kept until the listing is over.
        try withExtendedLifetime(registration) { try pass(relay, to: receive, ticket: ticket) }
    }

    /// Hands the batches of a relay to `receive` until the listing is over, `receive` wants no
    /// more, or the asker has left.
    private static func pass(_ relay: ListingRelay, to receive: ([FileItem]) -> Bool, ticket: CallBook.Ticket)
        throws
    {
        var event = relay.next()
        while case .batch(let items) = event {
            let wantsMore = receive(items)
            relay.reply(wantsMore)
            guard wantsMore else {
                // The file system has been told; it is not waited for.
                ticket.cancel()
                return
            }
            event = relay.next()
        }
        if case .finished(let result) = event { try result?.get() }
    }
}
