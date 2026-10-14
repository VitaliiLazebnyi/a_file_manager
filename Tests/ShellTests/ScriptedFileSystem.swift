import AFMKernel
import Foundation
import TestSupport

/// A file system whose listing is told exactly what to do: it delivers prepared batches, can
/// hold at a chosen batch until a gate is opened (or the listing is cancelled), and counts how
/// many listings began and ended. It also answers `volume(of:)` with a settable figure, and
/// counts the questions. Everything else is a memory file system's.
/// Unchecked: what it records is guarded by `condition`; its switches are set by the test before use.
final class ScriptedFileSystem: FileSystemProvider, @unchecked Sendable {
    let inner: MemoryFileSystem
    private let condition = NSCondition()
    private var isOpen = false
    private var began = 0
    private var finished = 0
    private var asks = 0
    private var figure: VolumeInfo?

    /// The batches a listing delivers. Set before the first listing starts.
    var batches: [[FileItem]] = []
    /// What the folders at these paths deliver instead (the others deliver `batches`); they never hold.
    var batchesAt: [String: [[FileItem]]] = [:]
    /// The listing waits before this batch (`batches.count` waits after the last) until `open()`
    /// is called or its cancellation flag is set. Nil never waits.
    var holdBefore: Int?
    /// Thrown when the listing is let go from its hold (the hold must be set for this).
    var failure: (any Error)?
    /// The second batch is not delivered before this long after the listing began, so that the
    /// panel shows the first batches as a first piece while the rest is held.
    var pauseBeforeSecondBatch: TimeInterval = 0

    init(scheme: String = "script") { inner = MemoryFileSystem(scheme: scheme) }

    func url(_ path: String) -> URL { inner.url(path) }
    func item(named name: String, in folder: String, isDirectory: Bool = false) -> FileItem {
        FileItem(url: url(folder + "/" + name), name: name, isDirectory: isDirectory)
    }

    var listingsBegun: Int {
        condition.lock()
        defer { condition.unlock() }
        return began
    }
    var listingsEnded: Int {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }
    var volumeQuestions: Int {
        condition.lock()
        defer { condition.unlock() }
        return asks
    }
    var volumeFigure: VolumeInfo? {
        get {
            condition.lock()
            defer { condition.unlock() }
            return figure
        }
        set {
            condition.lock()
            figure = newValue
            condition.unlock()
        }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    var scheme: String { inner.scheme }
    var capabilities: FileSystemCapabilities { inner.capabilities }

    func list(_: URL, showHidden _: Bool) -> [FileItem] { batches.flatMap { $0 } }

    func list(_ directory: URL, showHidden _: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        let started = Date()
        let holds = batchesAt[directory.path] == nil ? holdBefore : nil
        let batches = batchesAt[directory.path] ?? self.batches
        condition.lock()
        began += 1
        condition.unlock()
        defer {
            condition.lock()
            finished += 1
            condition.unlock()
        }
        let waiting = cancellation.onCancel { [condition] in
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }
        defer { _ = waiting }
        for index in 0...batches.count {
            if index == holds {
                condition.lock()
                while !isOpen, !cancellation.isCancelled { condition.wait() }
                condition.unlock()
                if let failure, !cancellation.isCancelled { throw failure }
            }
            if index == 1, pauseBeforeSecondBatch > 0 {
                condition.lock()
                let end = started.addingTimeInterval(pauseBeforeSecondBatch)
                while !cancellation.isCancelled, end.timeIntervalSinceNow > 0 { condition.wait(until: end) }
                condition.unlock()
            }
            guard index < batches.count, !cancellation.isCancelled, receive(batches[index]) else { return }
        }
    }

    func volume(of _: URL) -> VolumeInfo? {
        condition.lock()
        defer { condition.unlock() }
        asks += 1
        return figure
    }

    func item(at url: URL) -> FileItem? { inner.item(at: url) }
    func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader { try inner.read(url) }
    func createDirectory(at url: URL) throws { inner.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { try inner.write(url) }
    func remove(_ url: URL) throws { try inner.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }
}
