public import AFMKernel
public import Foundation

/// One file operation (spec 07 › Job sequence, 20 › File-operation job).
///
/// It works through the file-system providers only: within one file system it uses that
/// system's own move and copy, between two it streams the contents from one to the other.
///
/// **Safety rules.** A file arrives under a temporary name and gets its real name only when it
/// is complete (and verified, if asked for), so an interrupted job never leaves a half-written
/// file that looks whole; the one exception is `TransferOptions.keepsPartialFiles`. Appending
/// and resuming build the longer file next to the old one and swap them at the end. A moved
/// file is removed at its source only after it has its real name at the target. Nothing is
/// ever deleted that was not transferred or listed first: a folder that cannot be read is left
/// alone, and a moved folder is removed only when it is empty.
///
/// **Threading.** `run()` blocks and is meant for a background thread, the job thread. That
/// thread walks the trees and takes every decision (what exists, what to overwrite) in
/// processing order. Where both sides are fast local storage, the data of small files is
/// copied by a bounded pool of workers meanwhile (a delete uses a smaller one for the files of
/// a folder); `run()` returns only when they are done.
/// The answers that hold "for all" are guarded by `decisions`, which also lets only one
/// question be open at a time; the counters are guarded by `counters`. Set the public
/// settings (`options`, `delegate`, `onRecord`, …) before `run()`; only `cancel()` may be
/// called from elsewhere.
///
/// Unchecked `Sendable`: the job goes to its own thread and to the workers of the pool. Its
/// state is guarded by `decisions` (the answers, `grains`), `counters` (progress, failures,
/// `createdFolders`), `delivery` (the order of the reports), `remembered` (`measures`) and
/// `pendingRemovals` (`deferred`, `kept`), or used by the job thread only (`topItems`,
/// `predictedRenames`, `enteredTargets`, `origins`, `pool`, `deletePool`, a batch's own
/// fields). The settings, `target` and `defersRemovals` do not change once a worker has
/// started: the settings are set before `run()`, the other two by the job thread before the
/// first worker. `delegate` is weak and only read.
public final class FileJob: @unchecked Sendable {
    /// Files up to this size go to the pool; larger ones are copied one after another, since
    /// several large streams at once only make a disk slower.
    public static let smallFileLimit: Int64 = 4 << 20
    /// Folders nested deeper than this are not entered; the walk goes one call deeper per
    /// level, on a thread of its own whose stack has room for exactly this many.
    internal static let depthLimit = 1_024
    /// The stack of the job's thread: room for `depthLimit` folders, one call each.
    private static let stackSize = 64 << 20
    /// Top-level sources on a server are remembered from the first count up to this many, so
    /// that each is asked about once and not three times.
    internal static let rememberedSources = 4_096
    /// A folder with at least this many items is still remembered past `rememberedLimit`.
    internal static let worthKeepingPastLimit = 64

    /// Where the patience runs out.
    ///
    /// A queue of its own, which gets its thread also when every thread of the shared queues is
    /// held by something that waits: the very state in which giving up matters.
    internal static let patienceClock = DispatchQueue(label: "afm.fileoperations.patience", qos: .userInitiated)

    /// Dates that went through a `Date` and back differ by less than this; nearer counts as
    /// the same moment on every volume.
    internal static let timestampNoise: TimeInterval = 0.001

    /// The target folders that were looked through for old temporary files already.
    internal static let swept = Guarded(Set<String>())

    /// How old an unfinished copy must be before it counts as left behind.
    internal static let staleTemporaryAge: TimeInterval = 24 * 60 * 60

    /// The user's umask: what a file streamed from another file system may not keep of its rights.
    internal static let umask: UInt16 = {
        let mask = Darwin.umask(0o022)
        Darwin.umask(mask)
        return UInt16(mask & 0o777)
    }()

    /// Fewer files than this are not worth handing to workers.
    internal static let parallelDeleteThreshold = 16

    /// How many folders of one level are listed side by side before their listings are added
    /// up and let go: the listings of a whole level at once could be the whole tree.
    internal static let measuredAtOnce = 256

    /// What the job does with its sources.
    public let kind: JobKind
    /// The items the job works on, in processing order.
    public let sources: [URL]
    /// Where the job goes.
    ///
    /// Always a real place: a folder of a branch view is replaced by the folder behind it when the
    /// job is made, and whatever else turns out to be another spelling of a real folder when the
    /// job starts.
    public private(set) var target: TargetSpec?
    /// Paste into the folder the files came from: the copy gets a free name instead of being refused.
    public var renamesSelfCopies = false
    /// New names for sources that stay where they are (a rename of several items at once), by
    /// the source's `locationKey`: such a source goes to that name in its own folder, and
    /// `target` only says which file system the job writes to.
    public var newNames: [String: String] = [:]
    /// The choices of the dialog and the configuration that the job acts on.
    public var options = TransferOptions()
    /// Held weakly; whoever starts the job keeps the delegate alive while it runs.
    ///
    /// A job whose delegate is gone stops at its first question instead of guessing an answer.
    public weak var delegate: any FileJobDelegate?
    /// Receives what was done to every item, for the operation log.
    ///
    /// Called on the job's threads, several at once during a parallel copy, so it must be safe for
    /// that.
    public var onRecord: (@Sendable (OperationRecord) -> Void)?
    /// Asked before a record is put together (two displayed paths each): false for the kinds
    /// nobody is going to write down.
    ///
    /// Nil: every record is made. Called like `onRecord`.
    public var wantsRecord: (@Sendable (OperationRecord.Verb, OperationRecord.Status) -> Bool)?
    /// The least time between two progress reports; the first always goes out.
    ///
    /// Zero reports every change, which a window does not need and a test wants.
    public var progressInterval: TimeInterval = 0
    /// How many small files are copied at the same time when the storage allows it.
    public var parallelWidth = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    /// The limit this job goes by; tests set a small one.
    internal var depthLimit = FileJob.depthLimit

    /// The file systems of the sources and the target.
    internal let fileSystems: FileSystemRegistry
    /// Set by whoever stops the job (`cancel()`, the progress window); ends waiting reads and writes.
    internal let cancellation: CancellationFlag
    /// Set when the user chose Abort or Cancel in a question; stops the workers too.
    internal let stop = CancellationFlag()

    /// Guards the answers that hold "for all", and lets only one question be open at a time.
    internal let decisions = NSLock()
    /// What happens to a file whose name is taken: the rule for the job, or "ask".
    internal var mode = OverwriteMode.ask
    /// Errors are skipped without a question ("Skip all").
    internal var skipAllErrors = false
    /// Folders that are not empty are deleted without a question ("All").
    internal var deleteAllNonEmpty = false
    /// Folders are merged into folders of the same name without a question ("All").
    internal var mergeAll = false
    /// Other volumes are entered without a question ("All Volumes").
    internal var entersVolumes = false
    /// The protection questions answered "All", as "reason-purpose".
    internal var confirmedForAll: [String] = []
    /// How coarsely the volume of a folder keeps dates, by the folder's key.
    ///
    /// Guarded by `decisions`.
    internal var grains: [String: TimeInterval] = [:]

    /// Guards the progress, the failures and `createdFolders`.
    internal let counters = NSLock()
    /// What is done so far.
    internal var done = Measure()
    /// What the job has to do, as the first count found it.
    internal var total = Measure()
    /// The bytes of the files that are being copied right now.
    internal var inFlightBytes: Int64 = 0
    /// The lines the progress shows for the item being worked on.
    internal var currentLines: [String] = []
    /// The lines of the item now being worked on, put together only when a report goes out.
    internal var pendingLines: (() -> [String])?
    /// When the last report went out (uptime in nanoseconds); 0 before the first.
    internal var lastReport: UInt64 = 0
    /// Held while the delegate is told the progress, so that the reports arrive in order and
    /// one at a time.
    ///
    /// Taken before `counters`, never the other way round. A delegate that holds a report back (a
    /// paused job) holds only this: the counters stay free.
    internal let delivery = NSLock()
    /// How many steps failed, whatever was answered.
    internal var failureCount = 0
    /// The first failures (up to 20), as "path: message".
    internal var failures: [String] = []
    /// The target folders the job created outside the walk (`ensureFolder`), by their keys.
    internal var createdFolders: Set<String> = []

    /// The workers that copy small files side by side; nil where the disks do not allow it.
    internal var pool: Pool?
    /// The workers that delete the files of a folder side by side; delete jobs only.
    internal var deletePool: Pool?

    /// What the first walk found below each folder, so that a folder that is skipped, or
    /// moved by one rename, is not walked again just to advance the counter.
    ///
    /// Kept by the hash of the folder's location (a rare clash only makes the progress bar a little
    /// wrong) and capped, so a huge tree costs no more than a few megabytes; a folder that is not
    /// in it is walked again. Past the limit only the folders worth the memory go on being kept, up
    /// to twice the limit: walking a big one again costs a lot, a small one little, and the small
    /// ones are the many that would otherwise crowd out the big ones that a later rename asks for.
    internal let remembered = NSLock()
    /// The counts of the folders, by the hash of their locations; guarded by `remembered`.
    internal var measures: [Int: Measure] = [:]
    /// How many folders `measures` keeps (twice as many of those worth it); tests set a small number.
    internal var rememberedLimit = 50_000
    /// Sources (folders of a move) that the first count took for a plain rename and counted as
    /// one item.
    ///
    /// Job thread only; filled before the walk starts.
    internal var predictedRenames: Set<String> = []
    /// What the first count learned about the top-level sources on a server; empty when it kept nothing.
    ///
    /// Job thread only.
    internal var topItems: [FileItem?] = []
    /// The target folders this job has written into (hashes of their `claimKey`): a second
    /// source folder that lands in one of them meets files the job itself put there.
    ///
    /// Job thread only.
    internal var enteredTargets: Set<Int> = []

    /// A Move to a file system that keeps what is written back for a while (`.deferredWrites`)
    /// may remove no source before `commit`: the removals wait here, in the order they were
    /// found (a folder after what it holds).
    ///
    /// Set before the walk starts; the list is guarded by `pendingRemovals`.
    internal var defersRemovals = false
    /// Guards `deferred` and `kept`.
    internal let pendingRemovals = NSLock()
    /// The removals that wait for the commit, in the order they were found.
    internal var deferred: [DeferredRemoval] = []
    /// Sources whose removal did not happen (skipped, failed, or the commit failed): they stay,
    /// and so does everything above them.
    ///
    /// The keys of those sources and of every folder above.
    internal var kept: Set<String> = []
    /// This many waiting removals are committed and carried out without waiting for the end.
    internal var deferredBatchSize = 10_000

    /// The origin mark (`quarantine(of:)`) of each source folder asked about, nil for none.
    ///
    /// Job thread only.
    internal var origins: [String: Data?] = [:]

    /// How long a file system on a server is given to tidy up after a step that failed or was
    /// stopped (to take a temporary file away again) before the job goes on without it.
    internal var cleanupPatience: TimeInterval = 10

    /// Whether the job is a move.
    internal var isMove: Bool { kind == .move }
    /// Whether the job is being stopped, by the user or by an answer.
    internal var isStopping: Bool { cancellation.isCancelled || stop.isCancelled }
    /// Whether links are copied as what they point to (never in a move).
    internal var followsLinks: Bool { options.links == .followLinks && kind != .move }

    /// True when the job would copy or move the items onto themselves.
    public var targetsSourceFolder: Bool {
        guard let target, case .transfer = kind, !renamesSelfCopies else {
            return false
        }
        // A move onto another spelling of its own name is a rename (letter case), not a refusal.
        return sources.contains { source in
            let destination = destination(for: source, in: target)
            return destination.isSameLocation(as: source)
                || (kind == .copy && FileIdentity.sameEntry(destination, source))
        }
    }

    /// A job of `kind` on `sources`, to `target` for a copy or move (nil for a delete), on
    /// `fileSystems`; `cancellation` stops it.
    public init(
        kind: JobKind,
        sources: [URL],
        target: TargetSpec?,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag()
    ) {
        self.kind = kind
        // Items are processed in case-insensitive name order (07 › Processing order).
        self.sources = Self.inProcessingOrder(sources)
        // A target in a branch view is the real folder behind it: every comparison of source
        // and target below is made between real places.
        self.target = target.map { spec in
            var real = spec
            real.directory = RealLocation.resolve(spec.directory, in: fileSystems)
            return real
        }
        self.fileSystems = fileSystems
        self.cancellation = cancellation
    }

    /// Stops the job, from any thread; a read or write that waits for a server ends at once.
    public func cancel() {
        cancellation.cancel()
    }

    /// Runs the job and returns when all of it is over.
    ///
    /// The work is done on a thread of the job's own, whose stack has room for the deepest tree the
    /// job enters (`depthLimit`); the calling thread waits for it.
    public func run() -> JobResult {
        // Unchecked `Sendable`: written by the job's thread before it signals `finished`, read
        // here only after the wait.
        final class Box: @unchecked Sendable {
            var result = JobResult()

            deinit {
                // Nothing to release.
            }
        }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        // Weak: the caller holds the job until `run()` returns, which is after the work. The
        // thread lives on for a moment after it signals, and must not keep the job alive meanwhile.
        let thread = Thread { [weak self] in
            if let self { box.result = work() }
            finished.signal()
        }
        thread.name = "afm.fileoperations.job"
        thread.stackSize = Self.stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        finished.wait()
        return box.result
    }

    /// The whole job, on its own thread: the count, the walk, and the result.
    internal func work() -> JobResult {
        var result = JobResult()
        decisions.withLock {
            mode = options.overwrite
            skipAllErrors = options.skipsErrors
        }
        deletePool = makeDeletePool()
        // A file system may show a folder of another one under a location of its own (a plain
        // path typed inside an archive): asked, it answers with the real folder, and that is
        // where the job then goes.
        if var spec = target, !spec.directory.isFileURL, let found = try? entry(at: spec.directory),
            found.url.scheme != spec.directory.scheme
        {
            spec.directory = found.url
            target = spec
        }
        let measured = countTotal()
        counters.withLock { total = measured }
        switch kind {
        case .transfer:
            runTransfer(&result)

        case .delete(let toTrash):
            runDelete(toTrash: toTrash, &result)
        }
        counters.withLock {
            result.failureCount = failureCount
            result.failures = failures
        }
        // The last word, so that a finished job shows as finished.
        if !result.cancelled { emit(force: true) }
        // The lines of the last item hold the job; they are not wanted any more.
        counters.withLock { pendingLines = nil }
        return result
    }

    deinit {
        // Nothing to release: the workers are done when `run()` returns.
    }
}
