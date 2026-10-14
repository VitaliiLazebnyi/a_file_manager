public import Foundation

/// The contents of one directory as read from its file system, with what a panel needs to
/// know about its surroundings. Read in the background, then handed to the panel's model.
public struct Listing: Sendable {
    public let directory: URL
    /// In file-system order; the model sorts them.
    public let items: [FileItem]
    /// The directory above; nil for a root.
    public let parent: URL?
    /// The top of the tree the directory belongs to.
    public let root: URL
    public let volume: VolumeInfo?

    public init(directory: URL, items: [FileItem], parent: URL?, root: URL, volume: VolumeInfo? = nil) {
        self.directory = directory
        self.items = items
        self.parent = parent
        self.root = root
        self.volume = volume
    }
}

/// Reads what a panel is asked to show. Everything here blocks on the file system and is
/// meant for a background thread; the results are applied to the model on the main thread.
public enum PanelLoader: Sendable {
    public struct Result: Sendable {
        public let listing: Listing
        /// The item the cursor should go to, when the location named a file.
        public let focus: String?
    }

    /// One piece of a directory that is read step by step.
    public struct Batch: Sendable {
        /// The directory and its surroundings; `items` holds only the entries of this batch.
        public let listing: Listing
        public let focus: String?
        /// The first batch replaces what the panel shows; later ones are added to it.
        public let isFirst: Bool
    }

    /// Reads a location completely. The location of a file leads to its folder, with the file
    /// as focus. With `climbing`, a folder that cannot be read is replaced by its nearest
    /// readable parent (a folder that vanished while the panel was showing it). Throws
    /// `CocoaError(.userCancelled)` when `cancellation` was set before the end: what had
    /// arrived by then is not a listing.
    public static func load(
        _ location: URL, showHidden: Bool, fileSystems: FileSystemRegistry, climbing: Bool = false,
        cancellation: CancellationFlag? = nil
    ) throws -> Result {
        var items: [FileItem] = []
        var first: Batch?
        try stream(
            location, showHidden: showHidden, fileSystems: fileSystems, climbing: climbing, cancellation: cancellation
        ) { batch in
            if batch.isFirst { first = batch }
            items += batch.listing.items
            return true
        }
        if cancellation?.isCancelled == true { throw CocoaError(.userCancelled) }
        guard let first else { throw FileSystemError.notSupported("Listing \(location.absoluteString)") }
        let header = first.listing
        return Result(
            listing: Listing(
                directory: header.directory, items: items, parent: header.parent, root: header.root,
                volume: header.volume),
            focus: first.focus)
    }

    /// Reads a location piece by piece, so a large or slow directory can be shown while it is
    /// still arriving. `receive` gets at least one batch (an empty directory gives one empty
    /// batch) and returns false to stop. An error is thrown, also after batches have been
    /// delivered: what had arrived by then is not the whole directory, and the caller decides
    /// what to do with it.
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
        _ location: URL, showHidden: Bool, fileSystems: FileSystemRegistry, climbing: Bool = false,
        cancellation: CancellationFlag? = nil, receive: (Batch) -> Bool
    ) throws {
        let provider = try fileSystems.provider(for: location)
        let location = location.standardized
        let cancellation = cancellation ?? CancellationFlag()
        var delivered = false

        func list(_ directory: URL, focus: String?) throws {
            let parent = provider.parent(of: directory)
            let root = roots.root(of: directory, parent: parent, in: provider)
            let volume = ask(provider, "volume " + directory.locationKey, cancellation) {
                provider.volume(of: directory, cancellation: $0)
            }
            if cancellation.isCancelled { return }
            func batch(_ items: [FileItem]) -> Batch {
                defer { delivered = true }
                return Batch(
                    listing: Listing(directory: directory, items: items, parent: parent, root: root, volume: volume),
                    focus: focus, isFirst: !delivered)
            }
            try listing(of: directory, showHidden: showHidden, in: provider, cancellation: cancellation) { items in
                !cancellation.isCancelled && receive(batch(items))
            }
            if !delivered, !cancellation.isCancelled { _ = receive(batch([])) }
        }

        do {
            try list(location, focus: nil)
        } catch {
            guard !delivered, !cancellation.isCancelled else { throw error }
            let item = ask(provider, "item " + location.locationKey, cancellation) {
                provider.item(at: location, cancellation: $0)
            }
            if let item, !item.isDirectory, let parent = provider.parent(of: location) {
                try list(parent, focus: item.name)
                return
            }
            guard climbing, !cancellation.isCancelled else { throw error }
            var current = location
            while let parent = provider.parent(of: current) {
                current = parent
                if (try? list(current, focus: nil)) != nil || delivered || cancellation.isCancelled { return }
            }
            throw error
        }
    }

    /// A question that may block, asked on a kernel thread and shared with whoever asks the
    /// same; nil when `cancellation` was set before the answer came.
    private static func ask<Answer: Sendable>(
        _ provider: any FileSystemProvider, _ question: String, _ cancellation: CancellationFlag,
        _ work: @escaping @Sendable (CancellationFlag) -> Answer?
    ) -> Answer? {
        if Thread.isMainThread { return work(cancellation) }
        return BlockingCalls.answer(from: provider, to: question, cancellation: cancellation, work) ?? nil
    }

    /// Lists a directory on a kernel thread and hands every batch to the calling thread, where
    /// `receive` runs as if the file system had called it. Returns when the listing is over,
    /// when `receive` wanted no more, or, without a word, when `cancellation` is set; the
    /// file system's thread is then left to come back in its own time.
    private static func listing(
        of directory: URL, showHidden: Bool, in provider: any FileSystemProvider, cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws {
        if cancellation.isCancelled { return }
        if Thread.isMainThread {
            try provider.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
            return
        }
        let relay = Relay()
        let ticket = CallBook.shared.ask(
            owner: provider, question: "list \(showHidden ? "all" : "shown") " + directory.locationKey, shares: false,
            work: { flag -> Any in
                Swift.Result<Void, any Error> {
                    try provider.list(directory, showHidden: showHidden, cancellation: flag) { relay.offer($0) }
                }
            }, listener: { relay.finish($0 as? Swift.Result<Void, any Error>) })
        let registration = cancellation.onCancel {
            ticket.cancel()
            relay.abandon()
        }
        defer { withExtendedLifetime(registration) {} }
        while true {
            switch relay.next() {
            case .batch(let items):
                let wantsMore = receive(items)
                relay.reply(wantsMore)
                if !wantsMore {
                    // The file system has been told; it is not waited for.
                    ticket.cancel()
                    return
                }

            case .finished(let result):
                try result?.get()
                return

            case .abandoned:
                return
            }
        }
    }

    /// Passes batches from the thread that lists to the thread that asked, one at a time: the
    /// listing waits until the batch was taken and it is known whether more are wanted.
    /// All state is guarded by `condition`.
    private final class Relay: @unchecked Sendable {
        enum Event {
            case batch([FileItem])
            case finished(Swift.Result<Void, any Error>?)
            case abandoned
        }

        private let condition = NSCondition()
        private var pending: [FileItem]?
        private var answer: Bool?
        private var result: Swift.Result<Void, any Error>?
        private var isFinished = false
        /// Nobody takes batches any more: the asker has left, or wanted no more.
        private var isClosed = false

        /// Called by the listing; false when no more batches are wanted.
        func offer(_ items: [FileItem]) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard !isClosed else { return false }
            (pending, answer) = (items, nil)
            condition.broadcast()
            while answer == nil, !isClosed { condition.wait() }
            defer { answer = nil }
            return !isClosed && answer == true
        }

        /// Called by the asker: waits for the next thing to happen.
        func next() -> Event {
            condition.lock()
            defer { condition.unlock() }
            while pending == nil, !isFinished, !isClosed { condition.wait() }
            if isClosed { return .abandoned }
            if let items = pending {
                pending = nil
                return .batch(items)
            }
            return .finished(result)
        }

        func reply(_ wantsMore: Bool) {
            condition.lock()
            answer = wantsMore
            if !wantsMore { isClosed = true }
            condition.broadcast()
            condition.unlock()
        }

        func finish(_ result: Swift.Result<Void, any Error>?) {
            condition.lock()
            (self.result, isFinished) = (result, true)
            condition.broadcast()
            condition.unlock()
        }

        func abandon() {
            condition.lock()
            (isClosed, pending) = (true, nil)
            condition.broadcast()
            condition.unlock()
        }
    }

    private static let roots = RootCache()

    /// Remembers the top of the tree for the directories that were read a moment ago. A file
    /// system finds the top by going up one level at a time, which for a path thousands of
    /// levels deep (inside an archive) is thousands of steps over a long text each; the
    /// directory above was nearly always asked just before, and its top is this one's.
    /// All state is guarded by `lock`.
    private final class RootCache: @unchecked Sendable {
        private struct Entry {
            let root: URL
            let made: Date
        }

        private let lock = NSLock()
        private var known: [String: Entry] = [:]
        /// For how long an answer is trusted, in seconds: long enough for walking about in a
        /// tree, short enough for a file system whose tops can change.
        private let lifetime: TimeInterval = 30

        private func key(_ directory: URL, _ provider: any FileSystemProvider) -> String {
            "\(UInt(bitPattern: ObjectIdentifier(provider).hashValue)) " + directory.absoluteString
        }

        private func lookUp(_ key: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = known[key], -entry.made.timeIntervalSinceNow < lifetime else { return nil }
            return entry.root
        }

        func root(of directory: URL, parent: URL?, in provider: any FileSystemProvider) -> URL {
            var root = directory
            if let parent {
                // The directory above was nearly always read a moment ago. Otherwise the file
                // system is asked, which answers at once if it knows its tops, and climbs if not.
                root = lookUp(key(parent, provider)) ?? provider.root(of: parent)
            }
            lock.lock()
            if known.count >= 256 { known.removeAll() }
            known[key(directory, provider)] = Entry(root: root, made: Date())
            lock.unlock()
            return root
        }
    }
}
