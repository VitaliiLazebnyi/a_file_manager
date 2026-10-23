import AFMKernel
import Foundation

/// The surroundings of one run of a file tool: the file systems it reads and writes
/// through, its progress and the questions it may ask.
///
/// **Threading.** A run belongs to its job, but `advance` and `isCancelled` may be called
/// from several threads at once (files are hashed side by side); everything else is used
/// from the job's own thread.
///
/// Unchecked `Sendable`: what several threads touch is guarded by `lock` (the reports also by
/// `reportLock`); `overwritesAll` and `journal` are used by the job's thread only (`create`,
/// `transaction`).
internal final class ToolRun: @unchecked Sendable {
    /// Files are read and written in blocks of this size, never as a whole.
    internal static let blockSize = 1 << 20
    /// The largest file `contents(of:)` reads as a whole unless told otherwise: 256 MiB.
    internal static let contentsLimit = 256 << 20

    /// The file systems the tool reads and writes through.
    internal let fileSystems: FileSystemRegistry
    /// Set when the user cancels; the tool checks it between blocks.
    internal let cancellation: CancellationFlag
    /// Where the progress goes: the job's window.
    private let report: @Sendable (JobProgress) -> Void
    /// Asks the user what to do about a file in the way.
    internal let askExisting: @Sendable (URL) -> ExistingFileChoice
    /// Guards the counters, the lines, the time of the last report and the origin.
    internal let lock = NSLock()
    /// Held while a report is made, so reports reach the window one at a time and in order.
    private let reportLock = NSLock()
    /// The bytes done so far (under `lock`).
    private var bytesDone: Int64 = 0
    /// The bytes of the whole run (under `lock`).
    private var bytesTotal: Int64 = 0
    /// The files done so far (under `lock`).
    private var itemsDone = 0
    /// The files of the whole run (under `lock`).
    private var itemsTotal = 0
    /// What the window says about the work at hand (under `lock`).
    private var lines: [String] = []
    /// When the last report was made (under `lock`).
    private var lastReport = Date.distantPast
    /// "Overwrite All" was answered (job thread only).
    internal var overwritesAll = false

    // MARK: Where the data came from

    /// Set by a tool whose outputs are made of what it reads (the parts of a split file, a
    /// file put together again, an encoded or decoded one): they then carry the mark of
    /// coming from elsewhere that their source carries (`quarantine(of:)`: a file on a
    /// server, a download), as a copy of it would.
    ///
    /// A program that was split, sent and put together again is still checked by the system when it
    /// is first opened. Not set by tools that write something about their sources (a list of
    /// checksums).
    internal var carriesOrigin: Bool {
        get { lock.withLock { carries } }
        set { lock.withLock { carries = newValue } }
    }
    /// Guarded by `lock`, like `origin`.
    private var carries = false
    /// The mark of coming from elsewhere of the first source opened that has one (under `lock`).
    private var origin: Data?

    /// The mark outputs get, once a source that has one was opened.
    internal var originMark: Data? {
        lock.lock()
        defer { lock.unlock() }
        return origin
    }

    /// Outputs made with `deferred`, in the order they were created.
    ///
    /// Job thread only.
    internal var journal: [ToolOutput] = []

    /// A run that reports to `report`, asks `askExisting` about files in the way, and is cancelled by
    /// `cancellation`.
    internal init(
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag,
        report: @escaping @Sendable (JobProgress) -> Void,
        askExisting: @escaping @Sendable (URL) -> ExistingFileChoice
    ) {
        self.fileSystems = fileSystems
        self.cancellation = cancellation
        self.report = report
        self.askExisting = askExisting
    }

    /// A run without a job (a tool used on its own, as in its tests): nothing is reported and existing files are
    /// overwritten.
    internal convenience init(fileSystems: FileSystemRegistry) {
        self.init(
            fileSystems: fileSystems,
            cancellation: CancellationFlag(),
            report: { _ in
                // Nobody watches.
            },
            askExisting: { _ in .overwrite }
        )
    }

    /// A run inside a job: progress goes to its window, questions through `ask`.
    internal convenience init(
        fileSystems: FileSystemRegistry,
        monitor: any JobMonitor,
        askExisting: @escaping @MainActor @Sendable (URL) -> ExistingFileChoice
    ) {
        self.init(
            fileSystems: fileSystems,
            cancellation: monitor.cancellation,
            report: { progress in monitor.report(progress) },
            askExisting: { url in monitor.ask { @MainActor @Sendable in askExisting(url) } }
        )
    }

    /// `name(2).ext`, `name(3).ext`, …: the first that is free (spec 08 › Decode).
    internal static func freeName(for url: URL, provider: any FileSystemProvider) -> URL {
        let (base, ext) = FileItem.split(url.lastPathComponent)
        func candidate(_ number: Int) -> URL {
            url.deletingLastPathComponent().appending(name: "\(base)(\(number))" + (ext.isEmpty ? "" : "." + ext))
        }
        var number = 2
        while provider.item(at: candidate(number)) != nil {
            number += 1
        }
        return candidate(number)
    }

    /// Whether two locations are one file: the same place, or (on this Mac) the same device and
    /// inode, which sees through letter case, links and symbolic links in the path.
    internal static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        first.isSameLocation(as: second) || first.isSameFile(as: second, followingLinks: true)
    }

    /// Keeps the mark of coming from elsewhere of a source, when outputs are to carry it and none was kept yet.
    internal func noteOrigin(of url: URL, in provider: any FileSystemProvider) {
        guard carriesOrigin, originMark == nil, let mark = provider.quarantine(of: url) else {
            return
        }
        lock.lock()
        if origin == nil {
            origin = mark
        }
        lock.unlock()
    }

    /// Throws `ToolError.cancelled` once the run is cancelled.
    internal func checkCancelled() throws {
        if cancellation.isCancelled {
            throw ToolError.cancelled
        }
    }

    // MARK: Progress

    /// Sets what the whole run is: its bytes and files.
    internal func expect(bytes: Int64, items: Int) {
        lock.lock()
        bytesTotal = bytes
        itemsTotal = items
        lock.unlock()
        advance(0, items: 0, force: true)
    }

    /// Shows what is being worked on.
    ///
    /// Safe from any thread.
    internal func show(_ lines: [String]) {
        lock.lock()
        self.lines = lines
        lock.unlock()
        advance(0, items: 0, force: true)
    }

    /// Counts bytes (and finished files) and passes the state on, at most twenty times a
    /// second; with `force` at once.
    ///
    /// Safe from any thread.
    internal func advance(_ bytes: Int64, items: Int, force: Bool) {
        // The decision is one step under the lock: a report that is due takes its turn at once
        // (the time of the last report moves on), so no other thread finds it due as well.
        let due = lock.withLock { () -> Bool in
            bytesDone += bytes
            itemsDone += items
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.05 else {
                return false
            }
            lastReport = now
            return true
        }
        guard due else {
            return
        }
        // One report at a time; the state is read after the turn has come, so that a later
        // report never shows less than an earlier one. A paused job blocks inside the report
        // of the thread whose turn it is, and every report after it queues up behind it.
        reportLock.lock()
        defer { reportLock.unlock() }
        let progress = lock.withLock {
            JobProgress(
                lines: lines,
                itemsDone: itemsDone,
                itemsTotal: itemsTotal,
                bytesDone: bytesDone,
                bytesTotal: bytesTotal
            )
        }
        report(progress)
    }

    deinit {
        // Nothing to release.
    }
}
