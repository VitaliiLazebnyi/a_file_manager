import AFMKernel
import Foundation
import TestSupport

/// A file system whose listing is told exactly what to do: it delivers prepared batches, can hold
/// at a chosen batch until a gate is opened (or the listing is cancelled), and counts how many
/// listings began and ended.
///
/// It also answers `volume(of:)` with a settable figure, and counts the questions. Everything else
/// is a memory file system's.
///
/// Unchecked: what it records is guarded by `condition`; its switches are set by the test before use.
internal final class ScriptedFileSystem: FileSystemProvider, @unchecked Sendable {
    /// The memory file system that answers everything but listings and volumes.
    internal let inner: MemoryFileSystem
    /// The batches a listing delivers.
    ///
    /// Set before the first listing starts.
    internal var batches: [[FileItem]] = []
    /// What the folders at these paths deliver instead (the others deliver `batches`); they never hold.
    internal var batchesAt: [String: [[FileItem]]] = [:]
    /// The listing waits before this batch (`batches.count` waits after the last) until `open()` is
    /// called or its cancellation flag is set.
    ///
    /// Nil never waits.
    internal var holdBefore: Int?
    /// Thrown when the listing is let go from its hold (the hold must be set for this).
    internal var failure: (any Error)?
    /// The folders at these paths are their own parents (and tops), as a file system that knows its
    /// top without climbing to it may say of that top.
    internal var ownParents: Set<String> = []
    /// The second batch is not delivered before this long after the listing began, so that the
    /// panel shows the first batches as a first piece while the rest is held.
    internal var pauseBeforeSecondBatch: TimeInterval = 0
    /// Once let go from its hold, the listing waits this long before the next batch: at least
    /// that much time lies between the pieces before and after the hold.
    internal var pauseAfterHold: TimeInterval = 0
    private let condition = NSCondition()
    private var isOpen = false
    private var began = 0
    private var finished = 0
    private var asks = 0
    private var figure: VolumeInfo?

    /// How many listings began.
    internal var listingsBegun: Int { condition.withLock { began } }
    /// How many listings ended.
    internal var listingsEnded: Int { condition.withLock { finished } }
    /// How many times the volume was asked about.
    internal var volumeQuestions: Int { condition.withLock { asks } }
    /// What `volume(of:)` answers.
    internal var volumeFigure: VolumeInfo? {
        get { condition.withLock { figure } }
        set { condition.withLock { figure = newValue } }
    }

    /// The memory file system's scheme, `scheme`.
    internal var scheme: String { inner.scheme }
    /// The memory file system's capabilities.
    internal var capabilities: FileSystemCapabilities { inner.capabilities }

    /// A file system of `scheme`.
    internal init(scheme: String) {
        inner = MemoryFileSystem(scheme: scheme)
    }

    /// A file system of the scheme `script`.
    internal convenience init() {
        self.init(scheme: "script")
    }

    /// The location of `path`.
    internal func url(_ path: String) -> URL {
        inner.url(path)
    }

    /// An entry called `name` in `folder`.
    internal func item(named name: String, in folder: String, isDirectory: Bool) -> FileItem {
        FileItem(url: url(folder + "/" + name), name: name, kind: .init(isDirectory: isDirectory))
    }

    /// A file called `name` in `folder`.
    internal func item(named name: String, in folder: String) -> FileItem {
        item(named: name, in: folder, isDirectory: false)
    }

    /// Lets every listing that holds go on.
    internal func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }

    /// Everything the batches hold, at once.
    internal func list(_: URL, showHidden _: Bool) -> [FileItem] {
        batches.flatMap(\.self)
    }

    /// Delivers the batches as the switches say.
    internal func list(
        _ directory: URL,
        showHidden _: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    )
        throws
    {
        let started = Date()
        let holds = batchesAt[directory.path] == nil ? holdBefore : nil
        let delivered = batchesAt[directory.path] ?? batches
        condition.withLock { began += 1 }
        defer { condition.withLock { finished += 1 } }
        let waiting = cancellation.onCancel { [condition] in condition.withLock { condition.broadcast() } }
        defer { _ = waiting }
        for index in 0...delivered.count {
            if index == holds {
                try hold(cancellation)
                if pauseAfterHold > 0 {
                    pause(until: Date(timeIntervalSinceNow: pauseAfterHold), cancellation)
                }
            }
            if index == 1, pauseBeforeSecondBatch > 0 {
                pause(until: started.addingTimeInterval(pauseBeforeSecondBatch), cancellation)
            }
            guard index < delivered.count, !cancellation.isCancelled, receive(delivered[index]) else {
                return
            }
        }
    }

    /// Answers with `volumeFigure`, counting the question.
    internal func volume(of _: URL) -> VolumeInfo? {
        condition.withLock {
            asks += 1
            return figure
        }
    }

    /// The memory file system's entry.
    internal func item(at url: URL) -> FileItem? {
        inner.item(at: url)
    }

    /// The memory file system's parent; the folder itself for `ownParents`.
    internal func parent(of directory: URL) -> URL? {
        ownParents.contains(directory.path) ? directory : inner.parent(of: directory)
    }

    /// The memory file system's top; a folder of `ownParents` is its own top.
    internal func root(of url: URL) -> URL {
        ownParents.contains(url.path) ? url : inner.root(of: url)
    }

    /// The memory file system's reader.
    internal func read(_ url: URL) throws -> any FileReader {
        try inner.read(url)
    }

    /// Makes a folder in the memory file system.
    internal func createDirectory(at url: URL) {
        inner.createDirectory(at: url)
    }

    /// The memory file system's writer.
    internal func write(_ url: URL) throws -> any FileWriter {
        try inner.write(url)
    }

    /// Removes from the memory file system.
    internal func remove(_ url: URL) throws {
        try inner.remove(url)
    }

    /// Moves in the memory file system.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }

    /// Copies in the memory file system.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }

    /// Waits until the gate is opened or the listing is told to stop; throws `failure` when the
    /// listing goes on.
    private func hold(_ cancellation: CancellationFlag) throws {
        condition.withLock {
            while !isOpen, !cancellation.isCancelled {
                condition.wait()
            }
        }
        if let failure, !cancellation.isCancelled {
            throw failure
        }
    }

    /// Waits until `end`, or until the listing is told to stop.
    private func pause(until end: Date, _ cancellation: CancellationFlag) {
        condition.withLock {
            while !cancellation.isCancelled, end.timeIntervalSinceNow > 0 {
                condition.wait(until: end)
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
