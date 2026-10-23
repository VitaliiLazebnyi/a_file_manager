import AFMContracts
public import AFMKernel
public import Foundation
import os

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
    private static let stackSize = 64 << 20
    /// Top-level sources on a server are remembered from the first count up to this many, so
    /// that each is asked about once and not three times.
    private static let rememberedSources = 4_096
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

    public let kind: JobKind
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

    internal let fileSystems: FileSystemRegistry
    internal let cancellation: CancellationFlag
    /// Set when the user chose Abort or Cancel in a question; stops the workers too.
    internal let stop = CancellationFlag()

    internal let decisions = NSLock()
    internal var mode = OverwriteMode.ask
    internal var skipAllErrors = false, deleteAllNonEmpty = false, mergeAll = false, entersVolumes = false
    internal var confirmedForAll: [String] = []
    /// How coarsely the volume of a folder keeps dates, by the folder's key.
    ///
    /// Guarded by `decisions`.
    internal var grains: [String: TimeInterval] = [:]

    internal let counters = NSLock()
    internal var done = Measure(), total = Measure()
    internal var inFlightBytes: Int64 = 0
    internal var currentLines: [String] = []
    /// The lines of the item now being worked on, put together only when a report goes out.
    internal var pendingLines: (() -> [String])?
    internal var lastReport: UInt64 = 0
    /// Held while the delegate is told the progress, so that the reports arrive in order and
    /// one at a time.
    ///
    /// Taken before `counters`, never the other way round. A delegate that holds a report back (a
    /// paused job) holds only this: the counters stay free.
    internal let delivery = NSLock()
    internal var failureCount = 0
    internal var failures: [String] = []
    internal var createdFolders: Set<String> = []

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
    internal var measures: [Int: Measure] = [:]
    internal var rememberedLimit = 50_000
    /// Sources (folders of a move) that the first count took for a plain rename and counted as
    /// one item.
    ///
    /// Job thread only; filled before the walk starts.
    internal var predictedRenames: Set<String> = []
    /// What the first count learned about the top-level sources on a server.
    ///
    /// Job thread only.
    private var topItems: [FileItem?]?
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
    internal let pendingRemovals = NSLock()
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

    internal var isMove: Bool { kind == .move }
    internal var isStopping: Bool { cancellation.isCancelled || stop.isCancelled }
    internal var followsLinks: Bool { options.links == .followLinks && kind != .move }

    /// True when the job would copy or move the items onto themselves.
    public var targetsSourceFolder: Bool {
        guard let target, case .transfer = kind, !renamesSelfCopies else {
            return false
        }
        // A move onto another spelling of its own name is a rename (letter case), not a refusal.
        return sources.contains {
            let destination = destination(for: $0, in: target)
            return destination.isSameLocation(as: $0) || (kind == .copy && FileIdentity.sameEntry(destination, $0))
        }
    }

    public init(
        kind: JobKind,
        sources: [URL],
        target: TargetSpec? = nil,
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

    public func cancel() {
        cancellation.cancel()
    }

    /// Runs the job and returns when all of it is over.
    ///
    /// The work is done on a thread of the job's own, whose stack has room for the deepest tree the
    /// job enters (`depthLimit`); the calling thread waits for it.
    public func run() -> JobResult {
        /// Unchecked `Sendable`: written by the job's thread before it signals `finished`, read
        /// here only after the wait.
        final class Box: @unchecked Sendable { var result = JobResult() }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        // Unowned: the caller holds the job until `run()` returns, which is after the work. The
        // thread lives on for a moment after it signals, and must not keep the job alive meanwhile.
        let thread = Thread { [unowned self] in
            box.result = work()
            finished.signal()
        }
        thread.name = "afm.fileoperations.job"
        thread.stackSize = Self.stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        finished.wait()
        return box.result
    }

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
        // Trashing takes each item whole; everything else is counted item by item.
        var measured = Measure(items: sources.count)
        if kind != .delete(toTrash: true) {
            // Asking a server about a file is a trip there: what the count learns is kept for the walk.
            let remembers = sources.count <= Self.rememberedSources && sources.contains { !$0.isFileURL }
            var items: [FileItem?] = []
            measured = Measure()
            for source in sources {
                let item = autoreleasepool { (try? entry(at: source)) ?? nil }
                if remembers { items.append(item) }
                measured += measureForTotal(source, item)
            }
            if remembers { topItems = items }
        }
        counters.withLock { total = measured }
        switch kind {
        case .transfer:
            runTransfer(&result)

        case .delete(let toTrash):
            do {
                for (slot, source) in sources.enumerated() {
                    try checkCancelled()
                    let deleted = try autoreleasepool { () throws -> Bool in
                        guard try hasSafeName(source, verb: toTrash ? .trash : .delete) else {
                            return false
                        }
                        return try toTrash
                            ? trash(source)
                            : deleteTree(source, item: topItem(slot, source), isTopLevel: true, tree: nil, depth: 0)
                    }
                    if deleted { result.completed.append(source) }
                }
            } catch {
                result.cancelled = true
                halt()
            }
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

    /// The entry of a top-level source: what the first count found, where that was kept.
    internal func topItem(_ slot: Int, _ source: URL) throws -> FileItem? {
        if let known = topItems?[slot] {
            try checkCancelled()
            return known
        }
        return try entry(at: source)
    }
}
