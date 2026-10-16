public import AFMContracts
public import AFMKernel
public import Foundation
import os

public enum JobKind: Equatable, Sendable {
    case transfer(TransferKind)
    case delete(toTrash: Bool)

    public static let copy = Self.transfer(.copy)
    public static let move = Self.transfer(.move)
}

/// Answers of the Overwrite dialog (07 › Choices). The "all" answers hold for the rest of the job.
public enum ConflictChoice: Equatable, Sendable {
    case overwrite, overwriteAll, skip, skipAll, overwriteAllOlder, cancel
    /// The copied file gets this name instead; if it is taken too, the question comes again.
    case rename(String)
    /// The file at the target is renamed to this name first, then the copy takes its place.
    case renameExisting(String)
    case autoRenameCopied, autoRenameExisting
    /// The source is added to the end of the file at the target (07 › Append).
    case append
    /// The file at the target is the beginning of the source; the rest is added.
    case resume
    case overwriteAllOlderOrSame, copyAllLarger, copyAllSmaller, renameOlderSkipNewer
}

public enum ErrorChoice: Sendable { case skip, skipAll, retry, abort }
/// Answers to "The directory … is not empty!" (07 › Delete › Questions).
public enum FolderDeleteChoice: Sendable { case delete, all, skip, cancel }

/// The second question about an item that is protected (07 › Read-only, hidden and system
/// targets; 07 › Delete › Questions). On the Mac "read only" is a file nobody may write to, and
/// "locked" a file with the Finder's Locked flag, which only shows when the change is refused.
public struct ProtectionQuestion: Sendable {
    public enum Reason: Sendable {
        case readOnly, hidden, locked
        /// The item cannot go to the Trash (a network share or a disk without one); the
        /// question is whether to delete it for good instead.
        case noTrash
    }
    public enum Purpose: Sendable { case overwrite, delete, move }

    public let reason: Reason
    public let purpose: Purpose
    public let item: FileItem
}

/// `all` answers the same question for the rest of the job.
public enum ProtectionChoice: Sendable { case proceed, all, skip, cancel }
/// Answers to "the folder already exists at the target".
public enum MergeChoice: Sendable { case merge, mergeAll, skip, cancel }

/// What a job did to one item, for the operation log (13 › Operation › Log file).
public struct OperationRecord: Sendable {
    public enum Verb: String, Sendable {
        case copy = "Copy"
        case move = "Move"
        case append = "Append"
        case delete = "Delete"
        case trash = "Move to Trash"
        case makeFolder = "New folder"
        case removeFolder = "Delete folder"
        case newFile = "New file"
        case rename = "Rename"
    }

    public enum Status: Equatable, Sendable {
        case done
        case failed(String)
        case skipped
    }

    public let verb: Verb
    /// Locations as shown to the user.
    public let source: String
    public let target: String?
    public let status: Status

    public init(_ verb: Verb, source: String, target: String? = nil, status: Status = .done) {
        self.verb = verb
        self.source = source
        self.target = target
        self.status = status
    }
}

/// The questions and the progress of a job. Questions are asked one at a time and may block
/// until the user answers; progress arrives from one thread at a time, but possibly from
/// another thread than the questions and while a question is open. Without a parallel copy
/// everything comes from the thread that runs the job.
public protocol FileJobDelegate: AnyObject {
    func job(_ job: FileJob, progress: JobProgress)
    func job(_ job: FileJob, conflictAt target: FileItem, source: FileItem) -> ConflictChoice
    func job(_ job: FileJob, failedAt url: URL, error: any Error) -> ErrorChoice
    func job(_ job: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice
    func job(_ job: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice
    func job(_ job: FileJob, mergeInto existing: FileItem, source: FileItem) -> MergeChoice
    /// A folder among what is deleted or moved is another volume (a mounted disk, disk image
    /// or share): whether to go on into it, and so delete or empty that volume too.
    func job(_ job: FileJob, crossVolumeAt folder: FileItem, purpose: ProtectionQuestion.Purpose) -> ProtectionChoice
}

/// Whoever does not care about the protection and merge questions goes ahead.
extension FileJobDelegate {
    public func job(_: FileJob, confirm _: ProtectionQuestion) -> ProtectionChoice { .proceed }
    public func job(_: FileJob, mergeInto _: FileItem, source _: FileItem) -> MergeChoice { .merge }
    /// Another volume is never entered without somebody saying so.
    public func job(_: FileJob, crossVolumeAt _: FileItem, purpose _: ProtectionQuestion.Purpose)
        -> ProtectionChoice
    { .skip }
}

public struct JobResult: Sendable {
    /// Top-level sources that were processed completely; the panel deselects these.
    public var completed: [URL] = []
    public var cancelled = false
    /// Target location of the last top-level item that was copied or moved.
    public var lastTarget: URL?
    /// Why the job did not start at all, as a message for the user.
    public var refusal: String?
    /// How many steps failed, whatever was answered to the error; and the first few messages.
    public var failureCount = 0
    public var failures: [String] = []
}

public enum FileJobError: LocalizedError {
    case copyToItself
    case intoOwnSubfolder(String)
    case targetIsFolder(String)
    case targetIsFile(String)
    case sourceMissing(String)
    case folderNotEmpty(String)
    case verifyFailed(String)
    case cannotResume(String)
    /// A listed entry whose name could lead out of its folder (`..`, a name with `/`).
    case unsafeName(String)
    /// A pipe, a device or a socket: there is nothing in it to copy, and reading it may never end.
    case specialFile(String)
    /// Append and Resume only continue a plain file; a link at the target would lead elsewhere.
    case notPlainFile(String)
    /// A folder that is another volume, which the user did not want entered.
    case otherVolume(String)
    case nestedTooDeep(String)

    public var errorDescription: String? {
        switch self {
        case .copyToItself: return "You cannot copy a file to itself!"
        case .intoOwnSubfolder(let path): return "You cannot copy \(path) into one of its own subfolders!"
        case .targetIsFolder(let path): return "A folder with the name \(path) already exists!"
        case .targetIsFile(let path): return "A file with the name \(path) already exists!"
        case .sourceMissing(let path): return "\(path) does not exist any more!"
        case .folderNotEmpty(let path): return "\(path) still contains items that could not be processed."

        case .verifyFailed(let path):
            return "Verify failed: the copy of \(path) differs from the original. It was removed."

        case .cannotResume(let path): return "\(path) is not a shorter, partial copy of the file; it cannot be resumed."

        case .unsafeName(let name):
            return "\"\(DisplayName.escaped(name))\" is not a valid file name here. It was not processed."

        case .specialFile(let path):
            return "\(path) is a pipe, a device or a socket, not a file with contents. It was not copied."

        case .notPlainFile(let path):
            return "\(path) is a link or not a plain file; it cannot be appended to or resumed."

        case .otherVolume(let path): return "\(path) is another volume (a mounted disk or share). It was left as it is."
        case .nestedTooDeep(let path): return "\(path) is nested too deep to be processed."
        }
    }
}

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
    public let kind: JobKind
    public let sources: [URL]
    /// Where the job goes. Always a real place: a folder of a branch view is replaced by the
    /// folder behind it when the job is made, and whatever else turns out to be another
    /// spelling of a real folder when the job starts.
    public private(set) var target: TargetSpec?
    /// Paste into the folder the files came from: the copy gets a free name instead of being refused.
    public var renamesSelfCopies = false
    /// New names for sources that stay where they are (a rename of several items at once), by
    /// the source's `locationKey`: such a source goes to that name in its own folder, and
    /// `target` only says which file system the job writes to.
    public var newNames: [String: String] = [:]
    public var options = TransferOptions()
    /// Held weakly; whoever starts the job keeps the delegate alive while it runs. A job whose
    /// delegate is gone stops at its first question instead of guessing an answer.
    public weak var delegate: any FileJobDelegate?
    /// Receives what was done to every item, for the operation log. Called on the job's
    /// threads, several at once during a parallel copy, so it must be safe for that.
    public var onRecord: (@Sendable (OperationRecord) -> Void)?
    /// Asked before a record is put together (two displayed paths each): false for the kinds
    /// nobody is going to write down. Nil: every record is made. Called like `onRecord`.
    public var wantsRecord: (@Sendable (OperationRecord.Verb, OperationRecord.Status) -> Bool)?
    /// The least time between two progress reports; the first always goes out. Zero reports
    /// every change, which a window does not need and a test wants.
    public var progressInterval: TimeInterval = 0
    /// How many small files are copied at the same time when the storage allows it.
    public var parallelWidth = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    /// Files up to this size go to the pool; larger ones are copied one after another, since
    /// several large streams at once only make a disk slower.
    public static let smallFileLimit: Int64 = 4 << 20
    /// Folders nested deeper than this are not entered; the walk goes one call deeper per
    /// level, on a thread of its own whose stack has room for exactly this many.
    static let depthLimit = 1_024
    /// The limit this job goes by; tests set a small one.
    var depthLimit = FileJob.depthLimit
    private static let stackSize = 64 << 20
    /// Top-level sources on a server are remembered from the first count up to this many, so
    /// that each is asked about once and not three times.
    private static let rememberedSources = 4_096

    private let fileSystems: FileSystemRegistry
    private let cancellation: CancellationFlag
    /// Set when the user chose Abort or Cancel in a question; stops the workers too.
    private let stop = CancellationFlag()

    private let decisions = NSLock()
    private var mode = OverwriteMode.ask
    private var skipAllErrors = false, deleteAllNonEmpty = false, mergeAll = false, entersVolumes = false
    private var confirmedForAll: [String] = []
    /// How coarsely the volume of a folder keeps dates, by the folder's key. Guarded by `decisions`.
    private var grains: [String: TimeInterval] = [:]

    private let counters = NSLock()
    private var done = Measure(), total = Measure()
    private var inFlightBytes: Int64 = 0
    private var currentLines: [String] = []
    /// The lines of the item now being worked on, put together only when a report goes out.
    private var pendingLines: (() -> [String])?
    private var lastReport: UInt64 = 0
    /// Held while the delegate is told the progress, so that the reports arrive in order and
    /// one at a time. Taken before `counters`, never the other way round. A delegate that
    /// holds a report back (a paused job) holds only this: the counters stay free.
    private let delivery = NSLock()
    private var failureCount = 0
    private var failures: [String] = []
    private var createdFolders: Set<String> = []

    private var pool: Pool?
    /// The workers that delete the files of a folder side by side; delete jobs only.
    private var deletePool: Pool?

    /// What the first walk found below each folder, so that a folder that is skipped, or
    /// moved by one rename, is not walked again just to advance the counter. Kept by the hash of the
    /// folder's location (a rare clash only makes the progress bar a little wrong) and capped, so
    /// a huge tree costs no more than a few megabytes; a folder that is not in it is walked again.
    /// Past the limit only the folders worth the memory go on being kept, up to twice the limit:
    /// walking a big one again costs a lot, a small one little, and the small ones are the
    /// many that would otherwise crowd out the big ones that a later rename asks for.
    private let remembered = NSLock()
    private var measures: [Int: Measure] = [:]
    var rememberedLimit = 50_000
    private static let worthKeepingPastLimit = 64
    /// Sources (folders of a move) that the first count took for a plain rename and counted as
    /// one item. Job thread only; filled before the walk starts.
    private var predictedRenames: Set<String> = []
    /// What the first count learned about the top-level sources on a server. Job thread only.
    private var topItems: [FileItem?]?
    /// The target folders this job has written into (hashes of their `claimKey`): a second
    /// source folder that lands in one of them meets files the job itself put there.
    /// Job thread only.
    private var enteredTargets: Set<Int> = []

    /// A Move to a file system that keeps what is written back for a while (`.deferredWrites`)
    /// may remove no source before `commit`: the removals wait here, in the order they were
    /// found (a folder after what it holds). Set before the walk starts; the list is guarded by
    /// `pendingRemovals`.
    private var defersRemovals = false
    private let pendingRemovals = NSLock()
    private var deferred: [DeferredRemoval] = []
    /// Sources whose removal did not happen (skipped, failed, or the commit failed): they stay,
    /// and so does everything above them. The keys of those sources and of every folder above.
    private var kept: Set<String> = []
    /// This many waiting removals are committed and carried out without waiting for the end.
    var deferredBatchSize = 10_000

    private struct DeferredRemoval {
        let url: URL
        let isFolder: Bool
        /// The job's own source that `url` lies below; nil for such a source itself.
        let tree: URL?
    }

    /// The origin mark (`quarantine(of:)`) of each source folder asked about, nil for none.
    /// Job thread only.
    private var origins: [String: Data?] = [:]

    private struct Cancelled: Error {}

    /// Size of a subtree: files plus folders, and the bytes of the files.
    private struct Measure {
        var items = 0
        var bytes: Int64 = 0

        static func + (a: Self, b: Self) -> Self {
            Self(items: a.items + b.items, bytes: a.bytes.addingSaturated(b.bytes))
        }
        static func += (a: inout Self, b: Self) { a = a + b }
    }

    /// How one item ended.
    private struct Outcome {
        /// Processed as far as the user is concerned; the panel deselects it.
        var finished: Bool
        /// Nothing of it is left at the source that a move would have to keep.
        var emptied: Bool
        var target: URL?

        static let skipped = Self(finished: false, emptied: false, target: nil)
    }

    /// What was decided for a file whose turn has come.
    /// Skipping is no plan: the planner answers nil.
    private enum Plan {
        case write(URL, replacing: Bool)
        /// The target is the source itself under another spelling of its name: a rename, and
        /// never anything that reads and writes the file.
        case rename(URL)
        case append(URL)
        case resume(URL)

        var target: URL {
            switch self {
            case .write(let url, _), .rename(let url), .append(let url), .resume(let url): return url
            }
        }

        var isRename: Bool {
            if case .rename = self { return true }
            return false
        }
    }

    /// The bytes one file in progress has contributed to the progress so far. It belongs to
    /// the thread that copies the file and changes under `counters`.
    private final class Flight {
        var bytes: Int64 = 0
        /// The origin mark the file gets from its source (see `originMark`).
        var origin: Data?
        /// What a failed try left under the real name ("keep partial files"), and how long it was.
        var partial: (url: URL, size: Int64)?
    }

    /// The workers that copy small files side by side. They run on the kernel's threads for
    /// work that blocks (`BlockingCalls.run`), not on a dispatch queue: a worker waits for a
    /// disk, and a disk that has stopped answering must not take threads from the queues the
    /// rest of the program shares.
    private final class Pool: Sendable {
        let slots: DispatchSemaphore
        private let width: Int

        init(width: Int) {
            self.width = width
            slots = DispatchSemaphore(value: width)
        }

        /// Takes the work out of `task` and runs it. The work is let go of when this returns: a
        /// local that held it until the end of the closure in `start` would still hold the job while
        /// the group is left.
        private static func runOnce(_ task: OSAllocatedUnfairLock<(@Sendable () -> Void)?>) {
            let taken = task.withLock { work in
                defer { work = nil }
                return work
            }
            taken?()
        }

        /// Starts `work` on a thread of its own; `group` is left when it has returned, and
        /// the worker's slot (taken by the caller beforehand) is given back.
        ///
        /// The work, and all it holds (the job), is let go of before the group is left: whoever
        /// waits for the group finds nothing of the job left on the worker's thread.
        func start(in group: DispatchGroup, _ work: @escaping @Sendable () -> Void) {
            group.enter()
            let task = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: work)
            BlockingCalls.run { [slots] in
                Self.runOnce(task)
                slots.signal()
                group.leave()
            }
        }

        /// Returns when no worker is busy any more: every slot is taken once and given back. Job thread only.
        func drain() {
            for _ in 0..<width { slots.wait() }
            for _ in 0..<width { slots.signal() }
        }
    }

    /// The items of one folder (or the job's sources): where their outcomes are collected
    /// while some of them are still being copied by the pool.
    ///
    /// Unchecked `Sendable`: the outcomes and `cancelled` are guarded by `lock`; the other
    /// properties are used by the job thread only.
    private final class Batch: @unchecked Sendable {
        let group = DispatchGroup()
        private let lock = NSLock()
        private var outcomes: [Outcome?]
        private var cancelled = false
        /// The targets this batch has given out so far (hashes of their `claimKey`): written,
        /// or still being written by a worker. Job thread only.
        var produced: Set<Int> = []
        /// The folder this batch writes into has received files of this job before.
        var isShared = false
        /// Whether a move within this batch stays on one volume, once known. Job thread only.
        var staysOnVolume: Bool?
        /// The items are copied one after another, in the order they come: their file system
        /// asked for that order (`readOrder(of:)`), which several readers at once would undo.
        var isSerial = false

        init(count: Int) { outcomes = Array(repeating: nil, count: count) }

        func set(_ slot: Int, _ outcome: Outcome) {
            lock.lock()
            outcomes[slot] = outcome
            lock.unlock()
        }

        func setCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        /// Waits for the workers and returns what is known; an item without an outcome was not reached.
        func settled() -> (outcomes: [Outcome?], cancelled: Bool) {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            return (outcomes, cancelled)
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

    /// How long a file system on a server is given to tidy up after a step that failed or was
    /// stopped (to take a temporary file away again) before the job goes on without it.
    var cleanupPatience: TimeInterval = 10

    /// The flag for a call that tidies up. The job's own flag will not do: once the job is
    /// stopped it would end the very call that removes what the stopped step left behind. A
    /// local disk answers; a server that has stopped answering is waited for `cleanupPatience`
    /// and no longer, so that neither Cancel nor the end of the program hangs on it.
    private func patience(with provider: any FileSystemProvider) -> CancellationFlag {
        let flag = CancellationFlag()
        guard provider.scheme != "file" else { return flag }
        Self.patienceClock.asyncAfter(deadline: .now() + cleanupPatience) { flag.cancel() }
        return flag
    }

    /// Where the patience runs out. A queue of its own, which gets its thread also when
    /// every thread of the shared queues is held by something that waits: the very state in
    /// which giving up matters.
    private static let patienceClock = DispatchQueue(label: "afm.fileoperations.patience", qos: .userInitiated)

    private var isMove: Bool { kind == .move }
    private var isStopping: Bool { cancellation.isCancelled || stop.isCancelled }
    private var followsLinks: Bool { options.links == .followLinks && kind != .move }

    /// The entry at `url`, asked in a way that ends when the job is cancelled. Throws then,
    /// since "nothing there" would be a wrong answer to act on. Not for cleaning up.
    private func entry(at url: URL) throws -> FileItem? {
        let found = (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation)
        if found == nil, cancellation.isCancelled { throw Cancelled() }
        return found
    }

    /// Where a top-level source goes in `target`.
    private func destination(for source: URL, in target: TargetSpec) -> URL {
        if let name = newNames[source.locationKey] { return source.deletingLastPathComponent().appending(name: name) }
        return target.url(for: source.lastPathComponent)
    }

    /// True when the job would copy or move the items onto themselves.
    public var targetsSourceFolder: Bool {
        guard let target, case .transfer = kind, !renamesSelfCopies else { return false }
        // A move onto another spelling of its own name is a rename (letter case), not a refusal.
        return sources.contains {
            let destination = destination(for: $0, in: target)
            return destination.isSameLocation(as: $0) || (kind == .copy && FileIdentity.sameEntry(destination, $0))
        }
    }

    /// Runs the job and returns when all of it is over. The work is done on a thread of the
    /// job's own, whose stack has room for the deepest tree the job enters (`depthLimit`); the
    /// calling thread waits for it.
    public func run() -> JobResult {
        /// Unchecked `Sendable`: written by the job's thread before it signals `finished`, read
        /// here only after the wait.
        final class Box: @unchecked Sendable { var result = JobResult() }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = self.work()
            finished.signal()
        }
        thread.name = "afm.fileoperations.job"
        thread.stackSize = Self.stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        finished.wait()
        return box.result
    }

    private func work() -> JobResult {
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
                        guard try hasSafeName(source, verb: toTrash ? .trash : .delete) else { return false }
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
    private func topItem(_ slot: Int, _ source: URL) throws -> FileItem? {
        if let known = topItems?[slot] {
            try checkCancelled()
            return known
        }
        return try entry(at: source)
    }

    /// A source is processed under its last name, like every entry of a folder: one that could
    /// lead out of its folder (`..` from a provider) is refused. False: reported and skipped.
    private func hasSafeName(_ source: URL, verb: OperationRecord.Verb) throws -> Bool {
        let name = source.lastPathComponent
        if Self.isSafeName(name) { return true }
        add(Measure(items: 1))
        _ = try attempt(verb, at: source) { throw FileJobError.unsafeName(name) }
        return false
    }

    private func runTransfer(_ result: inout JobResult) {
        guard let target else { return }
        pool = makePool()
        defersRemovals = isMove && fileSystems.capabilities(for: target.directory).contains(.deferredWrites)
        // Once per folder and run of the program: reading a very large folder takes a moment.
        let isFirstVisit = Self.swept.withLock { swept in
            if swept.count >= 1_024 { swept.removeAll() }
            return swept.insert(target.directory.locationKey).inserted
        }
        if isFirstVisit { Self.sweepStaleTemporaries(in: target.directory) }
        let batch = Batch(count: sources.count)
        do {
            var taken: Set<String> = []
            let slots = slotsInReadOrder()
            batch.isSerial = slots != Array(sources.indices)
            for slot in slots {
                let source = sources[slot]
                try checkCancelled()
                try autoreleasepool {
                    guard try hasSafeName(source, verb: isMove ? .move : .copy) else {
                        return batch.set(slot, .skipped)
                    }
                    var destination = destination(for: source, in: target)
                    if renamesSelfCopies, destination.isSameLocation(as: source) {
                        destination = UniqueName.available(
                            for: destination,
                            in: fileSystems,
                            cancellation: cancellation
                        ) {
                            taken.contains(Self.claimKey($0))
                        }
                        try checkCancelled()
                        taken.insert(Self.claimKey(destination))
                    }
                    let shownTarget = destination
                    report { ["From: \(self.display(source))", "To: \(self.display(shownTarget))"] }
                    guard let item = try topItem(slot, source) else {
                        add(Measure(items: 1))
                        _ = try attempt(.copy, at: source) { throw FileJobError.sourceMissing(self.display(source)) }
                        return batch.set(slot, .skipped)
                    }
                    try transfer(
                        item,
                        to: destination,
                        from: options.filter.base,
                        batch: batch,
                        slot: slot,
                        isTopLevel: true,
                        depth: 0
                    )
                }
            }
        } catch {
            result.cancelled = true
            // The workers stop with the job, and so does a progress window that holds them back.
            halt()
        }
        // Whatever the pool still copies is waited for, also after a cancel: nothing of the
        // job goes on once `run()` has returned.
        let settled = batch.settled()
        if settled.cancelled { result.cancelled = true }
        if defersRemovals {
            // Every writer is closed now. A job that ended early commits nothing and removes
            // nothing: the sources stay next to copies that may not be durable.
            if !result.cancelled, !isStopping {
                do { try flushDeferred() } catch { result.cancelled = true }
            }
            keepPendingRemovals()
        }
        for (slot, source) in sources.enumerated() {
            guard let outcome = settled.outcomes[slot], outcome.finished, !isKept(source) else { continue }
            result.completed.append(source)
            if let target = outcome.target { result.lastTarget = target }
        }
    }

    /// The order the sources are worked through: as they are (by name), unless their file
    /// system reads them better in another (`readOrder(of:)`: an archive that is one stream
    /// gives its files in the order they lie in it). Local files are never asked about.
    private func slotsInReadOrder() -> [Int] {
        let slots = Array(sources.indices)
        guard sources.count > 1, let first = sources.first, !first.isFileURL, let target,
            let from = try? fileSystems.provider(for: first), let to = try? fileSystems.provider(for: target.directory),
            from !== to,
            !sources.contains(where: { $0.scheme != first.scheme })
        else { return slots }
        let ordered = from.readOrder(of: sources)
        guard ordered.count == sources.count, ordered != sources else { return slots }
        var places: [String: [Int]] = [:]
        for slot in slots.reversed() { places[sources[slot].locationKey, default: []].append(slot) }
        var result: [Int] = []
        result.reserveCapacity(slots.count)
        for url in ordered {
            // An answer that is not the same files in another order is not followed.
            guard let slot = places[url.locationKey]?.popLast() else { return slots }
            result.append(slot)
        }
        return result
    }

    /// The entries of one source folder in the order their file system reads them best; see
    /// `slotsInReadOrder`. The order by name stays wherever the file system has no other.
    private func inReadOrder(_ items: [FileItem], from: any FileSystemProvider) -> [FileItem] {
        guard items.count > 1 else { return items }
        let urls = items.map(\.url)
        let ordered = from.readOrder(of: urls)
        guard ordered.count == urls.count, ordered != urls else { return items }
        var places: [String: [Int]] = [:]
        for index in items.indices.reversed() { places[urls[index].locationKey, default: []].append(index) }
        var result: [FileItem] = []
        result.reserveCapacity(items.count)
        for url in ordered {
            guard let index = places[url.locationKey]?.popLast() else { return items }
            result.append(items[index])
        }
        return result
    }

    /// Several files at once only where both ends answer at once: local volumes that are not
    /// spinning disks. Everything else gets a single stream.
    private func makePool() -> Pool? {
        guard options.copiesSmallFilesInParallel, parallelWidth > 1, let target, !sources.isEmpty,
            areFastAndLocal([target.directory] + sourceFolders())
        else { return nil }
        return Pool(width: parallelWidth)
    }

    /// The folders the sources lie in, each once: a list of files from anywhere has many. Of a
    /// very long list a spread sample is looked at; a wrong guess costs speed, nothing else.
    private func sourceFolders() -> [URL] {
        var folders: [URL] = []
        var seen = Set<String>()
        var last = ""
        for index in stride(from: 0, to: sources.count, by: max(1, sources.count / 4_096)) {
            let parent = sources[index].deletingLastPathComponent()
            let folder = parent.absoluteString
            if folder == last { continue }
            last = folder
            if seen.insert(folder).inserted { folders.append(parent) }
        }
        return folders
    }

    /// A few files at once for deleting, where the disk answers at once. Measured on APFS: four
    /// workers delete three times as fast as one, more cores gain almost nothing.
    private func makeDeletePool() -> Pool? {
        guard kind == .delete(toTrash: false), options.copiesSmallFilesInParallel, parallelWidth > 1,
            areFastAndLocal(sourceFolders())
        else { return nil }
        return Pool(width: min(4, parallelWidth))
    }

    private func areFastAndLocal(_ urls: some Sequence<URL>) -> Bool {
        // Many folders, few disks: each disk is asked about once.
        var devices = Set<dev_t>()
        for url in urls {
            if let device = FileIdentity.device(ofNearest: url), !devices.insert(device).inserted { continue }
            guard let provider = try? fileSystems.provider(for: url),
                let volume = provider.volume(of: url, cancellation: cancellation), volume.isLocal,
                !StorageMedium.isRotational(url)
            else { return false }
        }
        return true
    }

    // MARK: Copy and move

    /// Copies or moves one item with everything below it; its outcome goes to `batch`.
    /// `position` is where the copy filter stands in the folder that holds the item;
    /// `isTopLevel` is true for the job's own sources, whose targets are checked against them.
    /// `tree` is the job's own source that the item lies below (nil for such a source itself): a
    /// move that takes the item away afterwards walks down from there (`remove(_:below:)`).
    private func transfer(
        _ listed: FileItem,
        to destination: URL,
        from position: CopyFilter.Position,
        batch: Batch,
        slot: Int,
        isTopLevel: Bool = false,
        tree: URL? = nil,
        depth: Int
    ) throws {
        try checkCancelled()
        let item = followsLinks ? resolvingLink(listed) : listed
        if item.isRealDirectory {
            guard let inside = options.filter.entering(item.name, from: position) else {
                add(measuredBefore(item))
                return batch.set(slot, .skipped)
            }
            guard depth < depthLimit else {
                add(measuredBefore(item))
                _ = try attempt(isMove ? .move : .copy, at: item.url) {
                    throw FileJobError.nestedTooDeep(self.display(item.url))
                }
                return batch.set(slot, .skipped)
            }
            batch.set(
                slot,
                try transferFolder(
                    item,
                    to: destination,
                    position: inside,
                    isTopLevel: isTopLevel,
                    tree: tree,
                    depth: depth
                )
            )
            return
        }
        guard options.filter.admitsFile(item.name, at: position) else {
            add(Measure(items: 1, bytes: item.size))
            batch.set(slot, .skipped)
            return
        }
        try transferFile(item, to: destination, batch: batch, slot: slot, tree: tree)
    }

    /// Decides what happens to one file, here and now, and has it done: by the pool when the
    /// file is small and there is one, else on the spot.
    private func transferFile(_ item: FileItem, to destination: URL, batch: Batch, slot: Int, tree: URL?) throws {
        // Two items of one batch can aim at one name (a mask like `fixed.txt`, equally named
        // files from two folders of a list, names that differ only in letter case on a volume
        // that does not tell them apart): the second must find the first one finished, to see
        // the conflict, and what it then finds is this job's own work (`ownOutput`).
        let collides = batch.produced.contains(Self.claimHash(destination))
        if collides, batch.settled().cancelled { throw Cancelled() }
        if defersRemovals, pendingRemovals.withLock({ deferred.count }) >= deferredBatchSize {
            // A commit meets no file that is still being written under its temporary name.
            pool?.drain()
            try flushDeferred()
        }
        var plan: Plan?
        let planned = try attempt(isMove ? .move : .copy, at: item.url, target: destination) {
            plan = try self.plan(for: item, at: destination, ownOutput: collides || batch.isShared) {
                batch.produced.contains(Self.claimHash($0))
            }
            return true
        }
        guard planned, let decided = plan else {
            add(Measure(items: 1, bytes: item.size))
            if planned { record(isMove ? .move : .copy, item.url, destination, .skipped) }
            batch.set(slot, .skipped)
            return
        }
        let target = decided.target
        batch.produced.insert(Self.claimHash(target))
        // Asked here, on the job thread, once per source folder; the workers only use the answer.
        let origin = originMark(of: item.url.deletingLastPathComponent(), copiedTo: target)
        let work = { @Sendable () throws -> Outcome in
            let flight = Flight()
            flight.origin = origin
            defer { self.land(flight, Measure(items: 1, bytes: item.size)) }
            var removesSource = false
            let arrived = try self.attempt(self.verb(of: decided), at: item.url, target: target) {
                self.advance(flight, to: 0)
                // A Retry after a try that kept its partial file under the real name: that
                // file is the job's own and makes room for the next try.
                self.removePartial(of: flight)
                // A plugin that still holds changes to this file (an archive that is written
                // after a delay) writes them first: what is copied or moved is the file as the
                // user sees it. If that fails the file is not touched, and the user hears why.
                try self.fileSystems.flushPendingWrites(to: item.url, cancellation: self.cancellation)
                removesSource = try self.execute(decided, item, flight)
                return true
            }
            guard arrived else { return .skipped }
            if removesSource, self.isStillTheSource(target, of: item.url) {
                // Never reached as far as anyone knows: the plan refuses a target that is the
                // source. But a source is removed only when what was written is another file.
                return Outcome(finished: true, emptied: false, target: target)
            }
            if removesSource, self.defersRemovals {
                // The copy is not durable yet; the original goes after the commit.
                self.postponeRemoval(of: item.url, isFolder: false, tree: tree)
            } else if removesSource {
                // A move between volumes has copied the file; taking the original away is a step
                // of its own, so that a Retry here does not copy a second time. A locked
                // original is asked about, as it is when it is deleted.
                let removed = try self.attempt(.delete, at: item.url) {
                    try self.removing(item, at: item.url) { try self.remove(item.url, below: tree) }
                }
                if !removed { return Outcome(finished: false, emptied: false, target: target) }
            }
            return Outcome(finished: true, emptied: self.isMove, target: target)
        }
        guard let pool, !batch.isSerial, item.size <= Self.smallFileLimit, !decided.isRename,
            !renamesInPlace(item.url, target, batch)
        else {
            batch.set(slot, try work())
            return
        }
        pool.slots.wait()
        pool.start(in: batch.group) {
            do {
                batch.set(slot, try work())
            } catch {
                // Abort or Cancel in a question a worker asked: the whole job ends.
                self.halt()
                batch.setCancelled()
            }
        }
    }

    /// A move inside one file system is a rename when the system can do it; that is quick and
    /// stays on the job thread. On local disks that holds only within one volume: between two
    /// volumes a move is a copy and a removal, which the pool takes. The items of a batch share
    /// their two folders, so the volumes are looked at once per batch.
    private func renamesInPlace(_ source: URL, _ destination: URL, _ batch: Batch) -> Bool {
        guard isMove, let from = try? fileSystems.provider(for: source),
            let to = try? fileSystems.provider(for: destination),
            from === to
        else { return false }
        if let known = batch.staysOnVolume { return known }
        guard source.isFileURL, destination.isFileURL else { return true }
        let (here, there) = (
            FileIdentity.device(of: source.deletingLastPathComponent()),
            FileIdentity.device(ofNearest: destination.deletingLastPathComponent())
        )
        // Unknown counts as one volume, the way it always was.
        let stays = here == nil || there == nil || here == there
        batch.staysOnVolume = stays
        return stays
    }

    private func verb(of plan: Plan) -> OperationRecord.Verb {
        if case .append = plan { return .append }
        return isMove ? .move : .copy
    }

    /// Applies the overwrite rules (07 › Name collisions) to one file. Job thread only.
    /// `ownOutput`: what is found at the target may be a file this very job wrote, from another
    /// source that maps to the same name. `isTaken` names targets that are spoken for.
    /// Nil: the file is skipped.
    private func plan(for item: FileItem, at destination: URL, ownOutput: Bool, isTaken: (URL) -> Bool) throws -> Plan?
    {
        if destination.isSameLocation(as: item.url) { throw FileJobError.copyToItself }
        guard let existing = try entry(at: destination) else { return .write(destination, replacing: false) }
        // A file system that only shows the files of another answers with the real file.
        // The real place is then what is compared and written: the other spelling of it
        // would hide that source and target are one file.
        if !existing.isDirectory, existing.url.scheme != destination.scheme {
            return try plan(for: item, at: existing.url, ownOutput: ownOutput, isTaken: isTaken)
        }
        // The source under another spelling (letter case on a case-insensitive volume): no
        // conflict. A move is a rename onto itself; a copy would be a copy onto itself.
        if FileIdentity.sameEntry(existing.url, item.url) {
            if isMove { return .rename(destination) }
            throw FileJobError.copyToItself
        }
        // Another name of the very same file (a hard link): there is nothing to copy.
        if FileIdentity.sameFile(existing.url, item.url) { throw FileJobError.copyToItself }
        if existing.isRealDirectory { throw FileJobError.targetIsFolder(display(destination)) }
        let folder = destination.deletingLastPathComponent()
        switch try conflictChoice(existing, item, ownOutput: ownOutput) {
        case .skip, .skipAll, .cancel:
            return nil

        case .rename(let name):
            return try plan(for: item, at: folder.appending(name: name), ownOutput: ownOutput, isTaken: isTaken)

        case .autoRenameCopied:
            let free = UniqueName.available(
                for: destination,
                in: fileSystems,
                cancellation: cancellation,
                isTaken: isTaken
            )
            // A name found while the job was being stopped is not known to be free.
            try checkCancelled()
            return .write(free, replacing: false)

        case .renameExisting(let name):
            try fileSystems.provider(for: destination)
                .move(
                    destination,
                    to: folder.appending(name: name),
                    replacing: false,
                    cancellation: cancellation
                )
            record(.rename, destination, folder.appending(name: name), .done)
            return try plan(for: item, at: destination, ownOutput: ownOutput, isTaken: isTaken)

        case .autoRenameExisting:
            let free = UniqueName.available(
                for: destination,
                in: fileSystems,
                cancellation: cancellation,
                isTaken: isTaken
            )
            try checkCancelled()
            try fileSystems.provider(for: destination)
                .move(
                    destination,
                    to: free,
                    replacing: false,
                    cancellation: cancellation
                )
            record(.rename, destination, free, .done)
            return try plan(for: item, at: destination, ownOutput: ownOutput, isTaken: isTaken)

        case .append:
            guard isPlainFile(existing) else { throw FileJobError.notPlainFile(display(destination)) }
            return try mayTouch(existing, for: .overwrite) ? .append(destination) : nil

        case .resume:
            // A link has no length of its own and would pass for the start of anything.
            guard isPlainFile(existing) else { throw FileJobError.notPlainFile(display(destination)) }
            guard existing.size < item.size else { throw FileJobError.cannotResume(display(destination)) }
            return .resume(destination)

        default:
            return try mayTouch(existing, for: .overwrite) ? .write(destination, replacing: true) : nil
        }
    }

    /// A file with contents of its own: not a link (a write would land on what it points to),
    /// not a pipe or device. Asks the disk again for a local file, whatever the listing said.
    private func isPlainFile(_ item: FileItem) -> Bool {
        if item.isSymlink || item.isSpecial || item.isDirectory { return false }
        return !FileIdentity.isSymlink(item.url) && !FileIdentity.isSpecialNode(item.url, followingLinks: false)
    }

    /// The answer for this one file: from the rule that holds for the job, or from the user.
    /// What comes back is one of the single-file answers.
    private func conflictChoice(_ existing: FileItem, _ source: FileItem, ownOutput: Bool) throws -> ConflictChoice {
        try decisions.withLock {
            if mode == .ask {
                switch try delegateOrStop().job(self, conflictAt: existing, source: source) {
                case .overwriteAll: mode = .overwriteAll
                case .skipAll: mode = .skipAll
                case .overwriteAllOlder: mode = .overwriteOlder
                case .overwriteAllOlderOrSame: mode = .overwriteOlderOrSame
                case .copyAllLarger: mode = .copyLarger
                case .copyAllSmaller: mode = .copySmaller
                case .renameOlderSkipNewer: mode = .renameOlderSkipNewer
                case .autoRenameCopied: mode = .autoRenameCopied
                case .autoRenameExisting: mode = .autoRenameExisting
                case .cancel: throw Cancelled()
                case let single: return single
                }
            }
            if ownOutput {
                // The file at the target is one this job wrote a moment ago, from another source
                // of the same name. No rule "for all" was given with that in mind: only an
                // answer for this one file overwrites it. Under a rule both files are kept.
                switch mode {
                case .skipAll: return .skip
                case .autoRenameExisting: return .autoRenameExisting
                case .renameOlderSkipNewer: return isNewer(source, than: existing) ? .autoRenameExisting : .skip
                default: return .autoRenameCopied
                }
            }
            switch mode {
            case .ask, .overwriteAll: return .overwrite
            case .skipAll: return .skip
            case .overwriteOlder: return isNewer(source, than: existing) ? .overwrite : .skip
            case .overwriteOlderOrSame: return !isNewer(existing, than: source) ? .overwrite : .skip
            case .copyLarger: return source.size > existing.size ? .overwrite : .skip
            case .copySmaller: return source.size < existing.size ? .overwrite : .skip
            case .autoRenameCopied: return .autoRenameCopied
            case .autoRenameExisting: return .autoRenameExisting
            case .renameOlderSkipNewer: return isNewer(source, than: existing) ? .autoRenameExisting : .skip
            }
        }
    }

    /// Dates that went through a `Date` and back differ by less than this; nearer counts as
    /// the same moment on every volume.
    private static let timestampNoise: TimeInterval = 0.001

    /// FAT, exFAT, ZIP archives and many servers keep the time of change to two seconds (HFS+
    /// to one), so a file copied there comes back up to that much older: where one of the two
    /// files lies on such a volume, nearer than that counts as the same age. Between volumes
    /// that keep the time exactly (APFS) the times are compared as they are. Called with
    /// `decisions` held.
    private func isNewer(_ file: FileItem, than other: FileItem) -> Bool {
        file.modified.timeIntervalSince(other.modified)
            > max(Self.timestampNoise, grain(at: file.url), grain(at: other.url))
    }

    private func grain(at url: URL) -> TimeInterval {
        let key = url.deletingLastPathComponent().locationKey
        if let known = grains[key] { return known }
        let grain = FileIdentity.timestampGrain(of: url)
        if grains.count >= 256 { grains.removeAll() }
        grains[key] = grain
        return grain
    }

    /// The second question for an item nobody may write to, or a hidden one. False: leave it.
    private func mayTouch(_ item: FileItem, for purpose: ProtectionQuestion.Purpose) throws -> Bool {
        if options.ignoresProtection || item.isSymlink { return true }
        if options.asksAboutReadOnly, item.permissions & 0o222 == 0, try !confirm(.readOnly, purpose, item) {
            return false
        }
        if options.asksAboutHidden, item.isHidden, try !confirm(.hidden, purpose, item) { return false }
        return true
    }

    private func confirm(_ reason: ProtectionQuestion.Reason, _ purpose: ProtectionQuestion.Purpose, _ item: FileItem)
        throws -> Bool
    {
        try decisions.withLock {
            let key = "\(reason)-\(purpose)"
            if confirmedForAll.contains(key) { return true }
            switch try delegateOrStop()
                .job(
                    self,
                    confirm: ProtectionQuestion(reason: reason, purpose: purpose, item: item)
                )
            {
            case .proceed: return true

            case .all:
                confirmedForAll.append(key)
                return true

            case .skip: return false
            case .cancel: throw Cancelled()
            }
        }
    }

    /// True when the item has been copied for a move and its source is still to be removed.
    private func execute(_ plan: Plan, _ item: FileItem, _ flight: Flight) throws -> Bool {
        let removesSource: Bool
        switch plan {
        case .write(let destination, let replacing):
            removesSource = try put(item, at: destination, replacing: replacing, flight)
            record(isMove ? .move : .copy, item.url, destination, .done)

        case .rename(let destination):
            // The file under another spelling of its own name. Only a rename can do that; a
            // copy would be written over the file and the move would then remove it.
            let (from, to) = (try fileSystems.provider(for: item.url), try fileSystems.provider(for: destination))
            guard from === to else { throw FileJobError.copyToItself }
            do {
                try from.move(item.url, to: destination, replacing: true, cancellation: cancellation)
            } catch FileSystemError.crossesVolumes {
                throw FileJobError.copyToItself
            }
            record(.move, item.url, destination, .done)
            return false

        case .append(let destination):
            removesSource = try extend(destination, with: item, resuming: false, flight)
            record(.append, item.url, destination, .done)

        case .resume(let destination):
            removesSource = try extend(destination, with: item, resuming: true, flight)
            record(isMove ? .move : .copy, item.url, destination, .done)
        }
        return removesSource
    }

    /// Brings one file or link to `destination`, by the cheapest way that works. True when it
    /// was copied for a move: the caller removes the source, as a step that can be retried.
    private func put(_ item: FileItem, at destination: URL, replacing: Bool, _ flight: Flight) throws -> Bool {
        let (from, to) = (try fileSystems.provider(for: item.url), try fileSystems.provider(for: destination))
        try ensureFolder(destination.deletingLastPathComponent(), in: to)
        if isMove, from === to {
            do {
                try from.move(item.url, to: destination, replacing: replacing, cancellation: cancellation)
                return false
            } catch FileSystemError.crossesVolumes {}
        }
        // From here on the file is read and written anew, which must never happen onto the file
        // itself: the copy would take the source's place, and a move would then remove it.
        if isStillTheSource(destination, of: item.url) { throw FileJobError.copyToItself }
        // A pipe or a device is not read: there is nothing in it to copy, and opening it may
        // never return. A link to one is still copied where links are copied as links.
        if item.isSpecial || FileIdentity.isSpecialNode(item.url, followingLinks: true) {
            let copiesLink = from === to && !followsLinks && (item.isSymlink || FileIdentity.isSymlink(item.url))
            if !copiesLink { throw FileJobError.specialFile(display(item.url)) }
        }
        // The copy is written under a temporary name next to the target and renamed when it is
        // complete: a failed or interrupted copy never damages an existing file and never
        // leaves a partial one under the real name.
        let temporary = temporaryName(next: destination)
        do {
            try copyContents(of: item, to: temporary, from: from, to: to, flight)
            if options.verifies { try verify(temporary, against: item.url) }
            try to.move(temporary, to: destination, replacing: replacing, cancellation: cancellation)
        } catch {
            // What arrived of a stream can be kept for Resume, when that was asked for.
            let tidying = patience(with: to)
            if options.keepsPartialFiles, !replacing, !(error is FileJobError),
                let left = to.item(at: temporary, cancellation: tidying),
                left.size > 0, !left.isSymlink,
                (try? to.move(temporary, to: destination, replacing: false, cancellation: tidying)) != nil
            {
                flight.partial = (destination, left.size)
                throw error
            }
            discard(temporary, in: to)
            throw error
        }
        return isMove
    }

    /// True when `target` is the very file `source` is, as far as that can be known: the same
    /// place once every view is seen through, or the same file on a local disk. What was
    /// written there is then not a second copy, and the source must stay.
    private func isStillTheSource(_ target: URL, of source: URL) -> Bool {
        let (there, here) = (
            RealLocation.resolve(target, in: fileSystems), RealLocation.resolve(source, in: fileSystems)
        )
        return there.isSameLocation(as: here) || FileIdentity.sameFile(there, here)
    }

    /// Takes away the partial file an earlier try of this flight left under the real name, if
    /// it is still that file. Nothing that was there before the job is ever touched by this.
    private func removePartial(of flight: Flight) {
        guard let partial = flight.partial else { return }
        flight.partial = nil
        guard let provider = try? fileSystems.provider(for: partial.url),
            let left = provider.item(at: partial.url, cancellation: cancellation),
            !left.isDirectory, !left.isSymlink, left.size == partial.size
        else { return }
        try? provider.remove(partial.url, cancellation: cancellation)
    }

    /// Removes the temporary file of a failed transfer. A copy of a locked file is locked too,
    /// and the system refuses to remove or rename such a file; it is unlocked the way a locked
    /// item is when the user agrees to delete it (`removing`), and removed again.
    private func discard(_ temporary: URL, in provider: any FileSystemProvider) {
        // Tidying up: the job may be stopped already, which must not keep the file from going.
        let tidying = patience(with: provider)
        do {
            try provider.remove(temporary, cancellation: tidying)
            return
        } catch  where Self.isRefusedAsLocked(error) {
            // Never a link: the change of permissions would land on what it points to.
            if let left = provider.item(at: temporary, cancellation: tidying), !left.isSymlink {
                try? provider.setAttributes(
                    FileAttributes(permissions: left.permissions | 0o200),
                    of: temporary,
                    cancellation: tidying
                )
                if (try? provider.remove(temporary, cancellation: tidying)) != nil { return }
            }
        } catch {}
        // Still there (a job that is being stopped does not ask): the user hears of it.
        if !isStopping, provider.item(at: temporary, cancellation: cancellation) != nil {
            note(.delete, at: temporary, "This temporary file of an interrupted copy could not be removed.")
        }
    }

    /// `.afm-<UUID>.tmp`, the name every unfinished copy carries.
    static func isTemporaryName(_ name: String) -> Bool {
        name.utf8.count == 45 && name.hasPrefix(".afm-") && name.hasSuffix(".tmp")
            && UUID(uuidString: String(name.dropFirst(5).dropLast(4))) != nil
    }

    /// The target folders that were looked through for old temporary files already.
    private static let swept = Guarded(Set<String>())

    /// How old an unfinished copy must be before it counts as left behind.
    static let staleTemporaryAge: TimeInterval = 24 * 60 * 60

    /// Removes the unfinished copies that a crash or a failed clean-up left in the target
    /// folder long ago: plain files under the job's own temporary name that nobody has
    /// touched for a day. Local folders only.
    static func sweepStaleTemporaries(in directory: URL, now: Date = Date()) {
        guard directory.isFileURL, let stream = opendir(directory.path) else { return }
        defer { closedir(stream) }
        let limit = Int(now.timeIntervalSince1970 - staleTemporaryAge)
        while let entry = readdir(stream) {
            guard entry.pointee.d_namlen == 45 else { continue }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 46) { String(cString: $0) }
            }
            guard isTemporaryName(name) else { continue }
            let path = directory.path + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mtimespec.tv_sec < limit,
                info.st_ctimespec.tv_sec < limit
            else { continue }
            unlink(path)
        }
    }

    private func temporaryName(next destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
    }

    /// Copies to a free name. A cancelled or failed copy within one file system leaves nothing
    /// behind; of a stream the caller removes what arrived.
    private func copyContents(
        of item: FileItem,
        to destination: URL,
        from: any FileSystemProvider,
        to: any FileSystemProvider,
        _ flight: Flight
    ) throws {
        // A link that is followed is read through, which only a stream does.
        // (A link that was not followed, because it leads back into its own folder, comes
        // here as the link it is and is copied as one.)
        let followed = try followsLinks && !item.isSymlink && entry(at: item.url)?.isSymlink == true
        if from === to, !followed {
            do {
                // With the job's flag: a copy the file system makes in one piece (a clone, a
                // copy on a server) never asks how far it is, and ends with the job all the same.
                try from.copy(item.url, to: destination, cancellation: cancellation) { copied in
                    self.advance(flight, to: copied)
                    return !self.isStopping
                }
                if !options.preservesAttributes, !item.isSymlink {
                    try? to.setAttributes(
                        FileAttributes(modified: Date(), permissions: 0o644),
                        of: destination,
                        cancellation: cancellation
                    )
                }
                return
            } catch FileSystemError.crossesVolumes {
                // The file system cannot copy between these two places itself; stream instead.
            } catch {
                throw isStopping ? Cancelled() : error
            }
        }
        // Between two file systems the contents are read from one and written to the other.
        let reader = try from.read(item.url, cancellation: cancellation)
        defer { reader.close() }
        let writer = try to.write(destination, cancellation: cancellation)
        // A read or write that waits for a server ends when the job is cancelled or aborted.
        let tokens = interrupting(reader) + interrupting(writer)
        defer { withExtendedLifetime(tokens) {} }
        do {
            try stream(reader, into: writer, flight, alreadyCopied: 0)
            try writer.close(attributes: attributes(for: item, from: from, to: to))
        } catch {
            try? writer.close(attributes: FileAttributes())
            throw error
        }
        if let origin = flight.origin { mark(destination, with: origin, in: to, shownAs: item.url) }
        // A followed link is streamed within one file system, which loses what copying would
        // have kept: tags, flags, creation date. They come from what the link points to.
        if followed, from === to, options.preservesAttributes, item.url.isFileURL {
            try? to.copyMetadata(from: item.url.resolvingSymlinksInPath(), to: destination, cancellation: cancellation)
        }
    }

    /// Ties a stream to the job's two stop signals: while the returned objects live, a cancel
    /// or an abort ends a read or write of `reader` that waits.
    private func interrupting(_ reader: any FileReader) -> [AnyObject] {
        [cancellation.interrupting(reader), stop.interrupting(reader)]
    }

    private func interrupting(_ writer: any FileWriter) -> [AnyObject] {
        [cancellation.interrupting(writer), stop.interrupting(writer)]
    }

    /// What a streamed copy gets. Rights that come from another file system (an archive, a
    /// server) were chosen by somebody else: set-user-ID, set-group-ID and the sticky bit
    /// never come along, and on the local disk the rest is cut by the user's umask, the way
    /// `tar` and `unzip` unpack.
    private func attributes(for item: FileItem, from: any FileSystemProvider, to: any FileSystemProvider)
        -> FileAttributes
    {
        guard options.preservesAttributes else { return FileAttributes() }
        var permissions = item.permissions
        if from !== to {
            permissions &= 0o777
            if to.scheme == "file" { permissions &= ~Self.umask }
        }
        return FileAttributes(modified: item.modified, permissions: permissions)
    }

    private static let umask: UInt16 = {
        let mask = Darwin.umask(0o022)
        Darwin.umask(mask)
        return UInt16(mask & 0o777)
    }()

    /// Puts the origin mark on what was copied. A file system that cannot keep marks does
    /// nothing; one that can and fails says so, and the user hears of it: the copy is there,
    /// but without the mark that it came from elsewhere.
    private func mark(_ url: URL, with origin: Data, in provider: any FileSystemProvider, shownAs shown: URL) {
        do {
            try provider.setQuarantine(origin, of: url, cancellation: cancellation)
        } catch {
            if !isStopping {
                note(
                    .copy,
                    at: shown,
                    "The copy could not be marked as coming from elsewhere: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Every block lives in a pool of its own: the buffers a reader hands out are otherwise
    /// kept until the thread ends, which for a job is after its last file.
    private func stream(_ reader: any FileReader, into writer: any FileWriter, _ flight: Flight, alreadyCopied: Int64)
        throws
    {
        var copied = alreadyCopied
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let block = try reader.read(upToCount: 1 << 20) else { return false }
            try checkCancelled()
            try writer.write(block)
            copied += Int64(block.count)
            advance(flight, to: copied)
            return true
        }) {}
    }

    /// Append and Resume: the file at the target followed by the source (all of it, or what
    /// the target lacks), written next to the target and swapped in when it is complete. The
    /// existing part is written again; in return the target stays whole until the longer file
    /// has fully arrived. A Resume on a file system that can continue a file (`.append`) does
    /// not copy the partial file at all: it is the file that grows, after a check that it
    /// really is the start of the source. An Append always takes the safe way.
    private func extend(_ destination: URL, with item: FileItem, resuming: Bool, _ flight: Flight) throws -> Bool {
        let (from, to) = (try fileSystems.provider(for: item.url), try fileSystems.provider(for: destination))
        // Looked at again here, right before the files are opened: only a plain file is
        // continued. A link would be read and written through to what it points to, and a
        // pipe on either side would never answer.
        guard let existing = try entry(at: destination) else { throw FileJobError.sourceMissing(display(destination)) }
        guard isPlainFile(existing) else { throw FileJobError.notPlainFile(display(destination)) }
        if item.isSpecial || FileIdentity.isSpecialNode(item.url, followingLinks: true) {
            throw FileJobError.specialFile(display(item.url))
        }
        if isStillTheSource(destination, of: item.url) { throw FileJobError.copyToItself }
        if resuming, to.capabilities(for: destination).contains(.append) {
            do {
                return try resumeInPlace(destination, partial: existing, with: item, from: from, to: to, flight)
            } catch FileSystemError.notSupported {
                // The file system cannot continue this one after all: write it anew.
            }
        }
        let temporary = temporaryName(next: destination)
        let writer = try to.write(temporary, cancellation: cancellation)
        let writerTokens = interrupting(writer)
        defer { withExtendedLifetime(writerTokens) {} }
        do {
            let head = try to.read(destination, cancellation: cancellation)
            defer { head.close() }
            let headTokens = interrupting(head)
            defer { withExtendedLifetime(headTokens) {} }
            var kept: Int64 = 0
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let block = try head.read(upToCount: 1 << 20) else { return false }
                try checkCancelled()
                try writer.write(block)
                kept += Int64(block.count)
                return true
            }) {}
            let reader = try from.read(item.url, cancellation: cancellation)
            defer { reader.close() }
            let readerTokens = interrupting(reader)
            defer { withExtendedLifetime(readerTokens) {} }
            if resuming {
                // The same check as when the file is continued in place: its end (all of it
                // when the job verifies) must be the source's, or the two do not belong together.
                guard kept < item.size,
                    try startsWithPartial(reader, destination, in: to, length: kept, fully: options.verifies, flight)
                else {
                    throw FileJobError.cannotResume(display(destination))
                }
                try reader.seek(to: UInt64(kept))
            }
            try stream(reader, into: writer, flight, alreadyCopied: resuming ? kept : 0)
            // A resumed file is the source and gets its date; an appended one is new now.
            try writer.close(
                attributes: resuming
                    ? attributes(for: item, from: from, to: to) : FileAttributes(permissions: existing.permissions)
            )
            if let origin = flight.origin { mark(temporary, with: origin, in: to, shownAs: item.url) }
            if resuming, options.verifies { try verify(temporary, against: item.url) }
            // The longer file is a new one: tags, comments, access rules and the date of
            // creation of the old one come along, last of all (a lock among them forbids the rest).
            try? to.copyMetadata(from: destination, to: temporary, cancellation: cancellation)
            // Tags and flags of the old file have come along; the mark of where the added
            // part came from must still be on the new one.
            if let origin = flight.origin, to.quarantine(of: temporary) == nil {
                mark(temporary, with: origin, in: to, shownAs: item.url)
            }
            try to.move(temporary, to: destination, replacing: true, cancellation: cancellation)
        } catch {
            try? writer.close(attributes: FileAttributes())
            discard(temporary, in: to)
            throw error
        }
        return isMove
    }

    /// Resume by continuing the partial file where it ends. The partial is first compared with
    /// the start of the source: its last block (up to 1 MB), or all of it when the job
    /// verifies, since a file that is not the start of the source would be joined to the wrong
    /// rest. A failed or cancelled continuation leaves the file as long as it got, as any
    /// partial file is.
    private func resumeInPlace(
        _ destination: URL,
        partial: FileItem,
        with item: FileItem,
        from: any FileSystemProvider,
        to: any FileSystemProvider,
        _ flight: Flight
    ) throws -> Bool {
        let kept = partial.size
        let reader = try from.read(item.url, cancellation: cancellation)
        defer { reader.close() }
        let readerTokens = interrupting(reader)
        defer { withExtendedLifetime(readerTokens) {} }
        guard try startsWithPartial(reader, destination, in: to, length: kept, fully: options.verifies, flight) else {
            throw FileJobError.cannotResume(display(destination))
        }
        let writer = try to.append(to: destination, at: kept, cancellation: cancellation)
        let writerTokens = interrupting(writer)
        defer { withExtendedLifetime(writerTokens) {} }
        do {
            advance(flight, to: kept)
            try stream(reader, into: writer, flight, alreadyCopied: kept)
            try writer.close(attributes: attributes(for: item, from: from, to: to))
        } catch {
            try? writer.close(attributes: FileAttributes())
            throw error
        }
        if let origin = flight.origin { mark(destination, with: origin, in: to, shownAs: item.url) }
        if options.verifies {
            do {
                try verify(destination, against: item.url)
            } catch {
                // What was added is taken off again, so that the file is the partial one it was.
                if let undo = try? to.append(to: destination, at: kept, cancellation: patience(with: to)) {
                    try? undo.close(attributes: FileAttributes())
                }
                throw error
            }
        }
        return isMove
    }

    /// Whether the first `length` bytes of `partial` are the first bytes of the source, which
    /// `reader` is then left at the end of. Without `fully` only the last block is compared.
    private func startsWithPartial(
        _ reader: any FileReader,
        _ partial: URL,
        in provider: any FileSystemProvider,
        length: Int64,
        fully: Bool,
        _ flight: Flight
    ) throws -> Bool {
        let head = try provider.read(partial, cancellation: cancellation)
        defer { head.close() }
        let headTokens = interrupting(head)
        defer { withExtendedLifetime(headTokens) {} }
        let block: Int64 = 1 << 20
        var position = fully ? 0 : max(0, length - block)
        try head.seek(to: UInt64(position))
        try reader.seek(to: UInt64(position))
        while position < length {
            try checkCancelled()
            let count = Int(min(block, length - position))
            let same = try autoreleasepool { () throws -> Bool in
                guard let mine = try Self.read(count, from: head),
                    let theirs = try Self.read(count, from: reader)
                else { return false }
                return mine == theirs
            }
            guard same else { return false }
            position += Int64(count)
            advance(flight, to: position)
        }
        return true
    }

    /// Exactly `count` bytes, or nil when the file ends first.
    private static func read(_ count: Int, from reader: any FileReader) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let block = try reader.read(upToCount: count - data.count), !block.isEmpty else { return nil }
            data.append(block)
        }
        return data
    }

    /// Reads the copy and the source again, each on its own core, and compares their checksums.
    /// Every block read shows the job's progress again, which is also where Pause takes hold.
    private func verify(_ copy: URL, against source: URL) throws {
        report(["Verifying: \(display(source))"])
        let digests = Parallel.map([source, copy]) { url in
            Result {
                try Checksum.sha256(
                    of: url,
                    in: self.fileSystems,
                    flags: [self.cancellation, self.stop],
                    isCancelled: {
                        self.emit(force: false)
                        return self.isStopping
                    }
                )
            }
        }
        let (original, written) = (try digests[0].get(), try digests[1].get())
        guard let original, let written else { throw Cancelled() }
        if original != written { throw FileJobError.verifyFailed(display(source)) }
    }

    private func transferFolder(
        _ folder: FileItem,
        to destination: URL,
        position: CopyFilter.Position,
        isTopLevel: Bool,
        tree: URL?,
        depth: Int
    ) throws -> Outcome {
        let source = folder.url
        let verb: OperationRecord.Verb = isMove ? .move : .copy
        // A folder that is another volume is not emptied by a move without somebody saying so.
        if isMove, try !mayEnter(folder, for: .move) {
            add(isMove && predictedRenames.contains(source.locationKey) ? Measure(items: 1) : measuredBefore(folder))
            record(verb, source, destination, .skipped)
            return .skipped
        }
        // With a filter a folder that gets no file may have to stay away: it is then created
        // with its first file.
        let createsLater = !options.filter.isEmpty && (options.filter.skipsEmptyFolders || !position.admitted)
        // The first count took this folder for one rename and counted it as one item.
        let predicted = isMove && predictedRenames.contains(source.locationKey)
        var movedWhole = false
        var createdHere = false
        let ready = try attempt(verb, at: source, target: destination) {
            if destination.isSameLocation(as: source) { throw FileJobError.copyToItself }
            if destination.isInside(source) || (isTopLevel && FileIdentity.isInside(destination, folder: source)) {
                throw FileJobError.intoOwnSubfolder(self.display(source))
            }
            if let existing = try self.entry(at: destination) {
                if FileIdentity.sameEntry(existing.url, source) {
                    // The folder under another spelling (letter case): a move renames it, a copy
                    // would merge it into itself.
                    guard self.isMove else { throw FileJobError.copyToItself }
                    try self.fileSystems.provider(for: source)
                        .move(
                            source,
                            to: destination,
                            replacing: true,
                            cancellation: self.cancellation
                        )
                    self.add(predicted ? Measure(items: 1) : self.measuredBefore(folder))
                    movedWhole = true
                    self.record(.move, source, destination, .done)
                    return true
                }
                // An existing folder is merged with the incoming one.
                guard existing.isRealDirectory else { throw FileJobError.targetIsFile(self.display(destination)) }
                return try self.mayMerge(into: existing, folder)
            }
            let (from, to) = (
                try self.fileSystems.provider(for: source), try self.fileSystems.provider(for: destination)
            )
            if self.isMove, from === to, self.options.filter.isEmpty {
                // A folder that does not exist at the target moves as a whole, when renaming can do it.
                // The size of what moves is known from the first count; only a folder that no one
                // has counted is walked, and it is not walked when the rename comes first.
                do {
                    try from.move(source, to: destination, replacing: false, cancellation: self.cancellation)
                    self.add(predicted ? Measure(items: 1) : self.measuredBefore(folder))
                    movedWhole = true
                    self.record(.move, source, destination, .done)
                    return true
                } catch FileSystemError.crossesVolumes {}
            }
            if !createsLater {
                try self.createFolder(destination, in: to)
                createdHere = true
                self.record(.makeFolder, destination, nil, .done)
            }
            return true
        }
        guard ready else {
            add(predicted ? Measure(items: 1) : measuredBefore(folder))
            return .skipped
        }
        if movedWhole { return Outcome(finished: true, emptied: true, target: destination) }
        if predicted {
            // The rename did not happen; the folder is copied item by item, so it counts as that.
            let inside = measure(folder)
            counters.withLock { total += Measure(items: inside.items - 1, bytes: inside.bytes) }
        }

        add(Measure(items: 1))
        // A folder whose contents could not be read was not transferred; it must stay.
        guard let listed = try listing(of: source) else { return .skipped }
        // Between two file systems the files are read in the order the source reads them best.
        var children = listed.items
        if !source.isFileURL, let from = try? fileSystems.provider(for: source),
            let to = try? fileSystems.provider(for: destination), from !== to
        {
            children = inReadOrder(children, from: from)
        }
        let batch = Batch(count: children.count)
        batch.isSerial =
            children.count == listed.items.count && zip(children, listed.items).contains { $0.url != $1.url }
        // A second source folder that lands in this target folder meets what the first one
        // brought; that is this job's own work and no rule "for all" overwrites it.
        batch.isShared = !enteredTargets.insert(Self.claimHash(destination)).inserted
        // Nothing of this folder is still being written when this function is left, however it is left.
        defer { batch.group.wait() }
        for (slot, child) in children.enumerated() {
            try autoreleasepool {
                let childTarget = destination.appending(name: child.name)
                report { ["From: \(self.display(child.url))", "To: \(self.display(childTarget))"] }
                try transfer(
                    child,
                    to: childTarget,
                    from: position,
                    batch: batch,
                    slot: slot,
                    tree: tree ?? source,
                    depth: depth + 1
                )
            }
        }
        let settled = batch.settled()
        if settled.cancelled { throw Cancelled() }
        // What was refused for its name stays where it is.
        var outcome = Outcome(
            finished: listed.rejected == 0 && settled.outcomes.allSatisfy { $0?.finished == true },
            emptied: listed.rejected == 0 && settled.outcomes.allSatisfy { $0?.emptied == true },
            target: destination
        )
        // A folder that waited for its first file (a filter was in the way) is the job's too, if one came.
        let madeLate = createsLater && !createdHere && (try? entry(at: destination)) != nil
        finishFolder(folder, at: destination, createdHere: createdHere || madeLate)
        if isMove, outcome.emptied, defersRemovals {
            postponeRemoval(of: source, isFolder: true, tree: tree)
        } else if isMove, outcome.emptied {
            // The provider removes only an empty folder, so whatever was not moved survives.
            outcome.emptied = try attempt(.removeFolder, at: source) {
                try self.remove(source, below: tree)
                return true
            }
            outcome.finished = outcome.finished && outcome.emptied
        }
        // With a filter, a folder that was entered counts as processed (07 › Only files of this type).
        if !options.filter.isEmpty { outcome.finished = true }
        return outcome
    }

    /// A folder gets its attributes when everything is inside: before, a folder without write
    /// permission could not be filled, and filling it would change its date.
    private func finishFolder(_ folder: FileItem, at destination: URL, createdHere: Bool) {
        let attributes = FileAttributes(
            modified: options.preservesFolderDates ? folder.modified : nil,
            permissions: createdHere && options.preservesAttributes ? folder.permissions : nil
        )
        guard let to = try? fileSystems.provider(for: destination) else { return }
        if attributes.modified != nil || attributes.permissions != nil {
            try? to.setAttributes(attributes, of: destination, cancellation: cancellation)
        }
        guard createdHere else { return }
        // Last of all: tags, flags and the date of creation come along, and a lock that does
        // would forbid the changes above. A file system that cannot do it does without.
        // The origin mark goes on before them: a lock among the flags would refuse it.
        if let origin = originMark(of: folder.url, copiedTo: destination) {
            mark(destination, with: origin, in: to, shownAs: folder.url)
        }
        if options.preservesAttributes {
            try? to.copyMetadata(from: folder.url, to: destination, cancellation: cancellation)
        }
    }

    /// Whether the job goes into `folder`. A folder that lies on another volume than the
    /// folder it is in is a mounted disk, disk image or share: deleting or moving "the folder"
    /// would empty that volume, so somebody has to say so first. False: it stays as it is,
    /// and that is noted.
    private func mayEnter(_ folder: FileItem, for purpose: ProtectionQuestion.Purpose) throws -> Bool {
        guard FileIdentity.isMountPoint(folder.url) else { return true }
        let allowed: Bool = try decisions.withLock {
            if entersVolumes { return true }
            if isStopping { throw Cancelled() }
            switch try delegateOrStop().job(self, crossVolumeAt: folder, purpose: purpose) {
            case .proceed: return true

            case .all:
                entersVolumes = true
                return true

            case .skip: return false
            case .cancel: throw Cancelled()
            }
        }
        if !allowed {
            note(
                purpose == .move ? .move : .removeFolder,
                at: folder.url,
                FileJobError.otherVolume(display(folder.url)).localizedDescription
            )
        }
        return allowed
    }

    /// What a file or folder copied from `source`'s file system to `destination`'s gets as the
    /// mark of coming from elsewhere (`quarantine(of:)` of the folder it is found in, asked once
    /// per folder). Nil inside one file system, which does its own copying. Job thread only,
    /// where asking the file system is allowed to take long.
    private func originMark(of folder: URL, copiedTo destination: URL) -> Data? {
        guard let from = try? fileSystems.provider(for: folder), let to = try? fileSystems.provider(for: destination),
            from !== to
        else { return nil }
        let key = folder.locationKey
        if let known = origins[key] { return known }
        let mark = from.quarantine(of: folder)
        if origins.count < rememberedLimit { origins[key] = .some(mark) }
        return mark
    }

    private func mayMerge(into existing: FileItem, _ folder: FileItem) throws -> Bool {
        guard options.asksBeforeMerging else { return true }
        return try decisions.withLock {
            if mergeAll { return true }
            switch try delegateOrStop().job(self, mergeInto: existing, source: folder) {
            case .merge: return true

            case .mergeAll:
                mergeAll = true
                return true

            case .skip: return false
            case .cancel: throw Cancelled()
            }
        }
    }

    /// Creates a target folder that the walk did not create (a filter was in the way, or the
    /// target of the whole job is new), once.
    private func ensureFolder(_ folder: URL, in provider: any FileSystemProvider) throws {
        guard !options.filter.isEmpty else { return }
        let key = folder.locationKey
        if counters.withLock({ createdFolders.contains(key) }) { return }
        if try entry(at: folder) == nil {
            try provider.createDirectory(at: folder, cancellation: cancellation)
            record(.makeFolder, folder, nil, .done)
        }
        counters.withLock { _ = createdFolders.insert(key) }
    }

    /// Makes a target folder that was not there a moment ago and is about to be filled. It
    /// is made exclusively: anything that has appeared under the name since it was looked for
    /// (a link somebody put there, which would lead everything copied into the folder
    /// somewhere else) is "already exists", and the step is asked about like any other that
    /// failed.
    private func createFolder(_ folder: URL, in provider: any FileSystemProvider) throws {
        try provider.createDirectory(at: folder, exclusive: true, cancellation: cancellation)
    }

    /// A link as the thing it points to, for a copy that follows links. A link that leads
    /// nowhere, or back to a folder it lies in, stays a link.
    private func resolvingLink(_ item: FileItem) -> FileItem {
        guard item.isSymlink else { return item }
        var target = item
        if item.url.isFileURL {
            let resolved = item.url.resolvingSymlinksInPath()
            guard let found = fileSystems.item(at: resolved), !item.url.isInside(resolved),
                !item.url.isSameLocation(as: resolved)
            else { return item }
            // "A folder it lies in" as the disk identifies folders (device and inode), not as
            // the paths read: the way to the link may itself lead through links, and then no
            // path of the link starts with the path of where it points.
            if found.isDirectory, FileIdentity.isInside(item.url, folder: resolved) { return item }
            target = found
        }
        return FileItem(
            url: item.url,
            name: item.name,
            kind: .init(
                isDirectory: item.isDirectory,
                isPackage: target.isPackage,
                isHidden: item.isHidden,
                isSpecial: target.isSpecial
            ),
            stat: .init(size: target.size, modified: target.modified, permissions: target.permissions)
        )
    }

    // MARK: Removing sources after a commit

    private func postponeRemoval(of url: URL, isFolder: Bool, tree: URL?) {
        pendingRemovals.withLock { deferred.append(DeferredRemoval(url: url, isFolder: isFolder, tree: tree)) }
    }

    /// Removes one entry: a file, a link or an empty folder. An entry of a tree the job
    /// walked into (`tree` is the top folder of that tree, one of the job's own sources) is
    /// removed by going down from that folder without following a link
    /// (`remove(_:below:cancellation:)`): should a folder on the way have been swapped for a
    /// link since it was listed, nothing is removed and the step fails, instead of an entry
    /// of the same name going wherever the link leads (F043). A source itself is removed by
    /// its path. File systems without such a walk remove by path in both cases.
    private func remove(_ url: URL, below tree: URL?) throws {
        let provider = try fileSystems.provider(for: url)
        if let tree, (try? fileSystems.provider(for: tree)) === provider {
            try provider.remove(url, below: tree, cancellation: cancellation)
        } else {
            try provider.remove(url, cancellation: cancellation)
        }
    }

    /// Whether `url`, or something below it, was kept at its source.
    private func isKept(_ url: URL) -> Bool {
        pendingRemovals.withLock { kept.contains(url.locationKey) }
    }

    /// Notes that `url` stays, and with it every folder above. Called with `pendingRemovals` held.
    private func keep(_ url: URL) {
        var current = url
        // A folder that is noted has everything above it noted too.
        while kept.insert(current.locationKey).inserted {
            let above = current.deletingLastPathComponent()
            guard above.path.count < current.path.count else { break }
            current = above
        }
    }

    /// What still waits when the job is over was not removed.
    private func keepPendingRemovals() {
        pendingRemovals.withLock {
            deferred.forEach { keep($0.url) }
            deferred = []
        }
    }

    /// Makes what was written durable, then removes the sources that wait, files before the
    /// folders that held them. Every writer of the waiting files is closed. If the commit
    /// fails nothing is removed: the user is told, as for any failed step, and the job ends.
    private func flushDeferred() throws {
        let pending = pendingRemovals.withLock { () -> [DeferredRemoval] in
            defer { deferred = [] }
            return deferred
        }
        guard !pending.isEmpty, let target else { return }
        var done = 0
        // Whatever was not removed stays, however this is left.
        defer { pendingRemovals.withLock { pending[done...].forEach { keep($0.url) } } }
        try checkCancelled()
        let folder = target.directory
        // Said before the writing starts, which is also where a paused job waits: a commit
        // that is under way cannot be held back, one that has not begun can.
        report(["Writing: \(display(folder))"])
        emit(force: true)
        try checkCancelled()
        do {
            // The file system asks between the members it writes (or the blocks it sends):
            // a report goes out when one is due, which is where a paused job waits, so Pause
            // takes hold inside the commit too; false ends it.
            try fileSystems.provider(for: folder)
                .commit(folder, cancellation: cancellation) { [self] _, _ in
                    if counters.withLock({ isDue }) { emit(force: false) }
                    return !isStopping
                }
        } catch {
            if isStopping { throw Cancelled() }
            // Nothing written since the last commit can be relied on. A Retry would only ask
            // again for the same answer, never remove anything.
            _ = try attempt(.move, at: folder) { throw error }
            stop.cancel()
            throw Cancelled()
        }
        for removal in pending {
            try checkCancelled()
            // Shown like every other step, which is also where a paused job waits.
            report { ["Deleting: \(self.display(removal.url))"] }
            if isKept(removal.url) {
                // Something inside was not removed, so this folder cannot be.
                done += 1
                continue
            }
            let removed = try attempt(removal.isFolder ? .removeFolder : .delete, at: removal.url) {
                try self.remove(removal.url, below: removal.tree)
                return true
            }
            done += 1
            if !removed { pendingRemovals.withLock { keep(removal.url) } }
        }
    }

    // MARK: Delete

    private func trash(_ source: URL) throws -> Bool {
        report(["Deleting: \(display(source))"])
        defer { add(Measure(items: 1)) }
        let item = try entry(at: source)
        var unsupported: any Error?
        let trashed = try attempt(.trash, at: source) {
            do {
                try self.flushBeforeRemoving(source, item)
                let removed = try self.removing(item, at: source) {
                    try self.fileSystems.provider(for: source).trash(source)
                }
                self.record(.trash, source, nil, removed ? .done : .skipped)
                return removed
            } catch let error where Self.isNoTrash(error) {
                // A network share or a disk without a Trash refuses; the system has no way to ask
                // beforehand. The item is still there, so the user may have it deleted for good.
                unsupported = error
                return false
            }
        }
        guard let error = unsupported else { return trashed }
        guard let item else { return try attempt(.trash, at: source) { throw error } }
        guard try confirm(.noTrash, .delete, item) else {
            record(.trash, source, nil, .skipped)
            return false
        }
        return try deleteTree(source, item: item, isTopLevel: true, tree: nil, depth: 0)
    }

    /// What the system answers when a place has no Trash at all, as opposed to a failure of
    /// this one item (no permission, the item vanished), which is the user's to deal with.
    static func isNoTrash(_ error: any Error) -> Bool {
        if case .notSupported? = error as? FileSystemError { return true }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.featureUnsupported.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOTSUP) || error.code == Int(EOPNOTSUPP) {
            return true
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? (any Error)).map(isNoTrash) ?? false
    }

    /// Deletes an item and everything below it, one entry at a time, so every entry is counted,
    /// can fail on its own, and the job can be cancelled in between. The files of a folder are
    /// deleted by a few workers at once where the disk allows it.
    ///
    /// `tree` is the job's own source that `url` lies below, nil for such a source itself;
    /// see `remove(_:below:)`.
    private func deleteTree(_ url: URL, item: FileItem?, isTopLevel: Bool, tree: URL?, depth: Int) throws -> Bool {
        try checkCancelled()
        report { ["Deleting: \(self.display(url))"] }
        var complete = true
        // Asked once more of the disk: a folder that somebody swapped for a link since it was
        // listed is a link, and is removed as one, never walked into.
        let isFolder = item?.isRealDirectory == true && !FileIdentity.isSymlink(url)
        if let item, isFolder {
            guard depth < depthLimit else {
                add(measuredBefore(item))
                _ = try attempt(.removeFolder, at: url) { throw FileJobError.nestedTooDeep(self.display(url)) }
                return false
            }
            // A folder that is another volume (a mounted disk image, a share) is not walked
            // into without somebody saying so: "deleting the folder" would erase that volume.
            guard try mayEnter(item, for: .delete) else {
                add(measuredBefore(item))
                record(.removeFolder, url, nil, .skipped)
                return false
            }
            // A folder that cannot be read is not deleted blindly.
            guard let listed = try listing(of: url, sorted: false) else {
                add(measuredBefore(item))
                return false
            }
            if isTopLevel, !listed.items.isEmpty, try !mayDeleteNonEmpty(url) {
                add(measuredBefore(item))
                record(.removeFolder, url, nil, .skipped)
                return false
            }
            if listed.rejected > 0 { complete = false }
            if try !deleteChildren(of: listed.items, tree: tree ?? url, depth: depth + 1) { complete = false }
        }
        defer { add(Measure(items: 1)) }
        // Something inside could not be deleted, so the folder stays.
        guard complete else { return false }
        return try deleteEntry(url, item: item, isFolder: isFolder, tree: tree)
    }

    /// Removes one file, link or empty folder, after the questions about protected items.
    private func deleteEntry(_ url: URL, item: FileItem?, isFolder: Bool, tree: URL?) throws -> Bool {
        let verb: OperationRecord.Verb = isFolder ? .removeFolder : .delete
        if let item, !isFolder, try !mayTouch(item, for: .delete) {
            record(verb, url, nil, .skipped)
            return false
        }
        return try attempt(verb, at: url) {
            if !isFolder { try self.flushBeforeRemoving(url, item) }
            let removed = try self.removing(item, at: url) { try self.remove(url, below: tree) }
            self.record(verb, url, nil, removed ? .done : .skipped)
            return removed
        }
    }

    /// A file that some plugin still holds changes for (an archive that is written after a
    /// delay) is brought up to date before it goes: otherwise the late writing would find
    /// its file gone, or put a file back that the user deleted. Files only.
    private func flushBeforeRemoving(_ url: URL, _ item: FileItem?) throws {
        guard let item, !item.isDirectory, !item.isSymlink else { return }
        try fileSystems.flushPendingWrites(to: url, cancellation: cancellation)
    }

    private func deleteLeaf(_ leaf: FileItem, tree: URL?) throws -> Bool {
        try checkCancelled()
        report { ["Deleting: \(self.display(leaf.url))"] }
        defer { add(Measure(items: 1)) }
        return try deleteEntry(leaf.url, item: leaf, isFolder: false, tree: tree)
    }

    /// The contents of a folder: its files first, then its subfolders one by one. False when
    /// something was kept.
    private func deleteChildren(of children: [FileItem], tree: URL, depth: Int) throws -> Bool {
        var complete = true
        let (folders, leaves) = (children.filter(\.isRealDirectory), children.filter { !$0.isRealDirectory })
        // The files that are going to ask a question come first, in name order, so that the
        // questions are asked as they always were; the listing itself is not sorted.
        let asking = Sorter.sorted(leaves.filter(mayAsk), byName: \.name)
        let quiet = leaves.filter { !mayAsk($0) }
        if let deletePool, quiet.count >= Self.parallelDeleteThreshold {
            if try !deleteLeaves(asking: asking, quiet: quiet, tree: tree, with: deletePool) { complete = false }
        } else {
            for leaf in asking + quiet where try autoreleasepool(invoking: { try !deleteLeaf(leaf, tree: tree) }) {
                complete = false
            }
        }
        for folder in folders
        where try autoreleasepool(invoking: {
            try !deleteTree(folder.url, item: folder, isTopLevel: false, tree: tree, depth: depth)
        }) {
            complete = false
        }
        return complete
    }

    /// Fewer files than this are not worth handing to workers.
    private static let parallelDeleteThreshold = 16

    /// Deletes files by the pool. A file that is going to ask a question (read-only, hidden) is
    /// done here, in the order given, while the workers delete the others; a question a worker
    /// meets later (a locked file) is asked under the same lock as any other. An Abort or Cancel
    /// in any of them stops the others, and the function returns only when the workers are done.
    private func deleteLeaves(asking: [FileItem], quiet: [FileItem], tree: URL, with pool: Pool) throws -> Bool {
        /// What the workers found out, under a lock of its own. Unchecked `Sendable`: all state
        /// is guarded by `lock`.
        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var kept = false
            var failure: any Error?
        }
        let tally = Tally()
        let group = DispatchGroup()
        for leaf in quiet {
            if isStopping { break }
            pool.slots.wait()
            pool.start(in: group) {
                do {
                    if try !self.deleteLeaf(leaf, tree: tree) { tally.lock.withLock { tally.kept = true } }
                } catch {
                    // Abort or Cancel in a question a worker asked: the whole job ends.
                    self.halt()
                    tally.lock.withLock { tally.failure = tally.failure ?? error }
                }
            }
        }
        // The workers are busy meanwhile with the files that ask nothing.
        var keptAsked = false
        do {
            for leaf in asking where try !deleteLeaf(leaf, tree: tree) {
                keptAsked = true
            }
        } catch {
            halt()
            tally.lock.withLock { tally.failure = tally.failure ?? error }
        }
        group.wait()
        return try tally.lock.withLock {
            if let failure = tally.failure { throw failure }
            if isStopping { throw Cancelled() }
            return !tally.kept && !keptAsked
        }
    }

    /// Whether the questions about protected items may come up for this file.
    private func mayAsk(_ item: FileItem) -> Bool {
        if options.ignoresProtection || item.isSymlink { return false }
        return (options.asksAboutReadOnly && item.permissions & 0o222 == 0)
            || (options.asksAboutHidden && item.isHidden)
    }

    private func mayDeleteNonEmpty(_ url: URL) throws -> Bool {
        guard options.asksAboutNonEmptyFolders else { return true }
        return try decisions.withLock {
            if deleteAllNonEmpty { return true }
            switch try delegateOrStop().job(self, confirmDeleteNonEmpty: url) {
            case .delete: return true

            case .all:
                deleteAllNonEmpty = true
                return true

            case .skip: return false
            case .cancel: throw Cancelled()
            }
        }
    }

    /// Runs a removal. When the system refuses because the item is locked, the user is asked,
    /// the item unlocked (the provider does that when it is made writable) and the removal
    /// tried once more. False: the user wants to keep the item.
    ///
    /// "Not permitted" has other reasons than a lock (a folder that only lets owners delete,
    /// a locked folder above): on a local disk only an item that really carries a lock is
    /// unlocked. A link is never unlocked this way, because the change of permissions would
    /// land on whatever it points to. And an item that could not be removed after all gets
    /// back the permissions and the lock it had.
    private func removing(_ item: FileItem?, at url: URL, _ remove: () throws -> Void) throws -> Bool {
        do {
            try remove()
            return true
        } catch let error where Self.isRefusedAsLocked(error) {
            guard let item, !item.isSymlink, !FileIdentity.isSymlink(url), FileIdentity.isLocked(url) != false else {
                throw error
            }
            if !options.ignoresProtection, try !confirm(.locked, .delete, item) { return false }
            let provider = try fileSystems.provider(for: url)
            let flags = FileIdentity.flags(of: url)
            try? provider.setAttributes(
                FileAttributes(permissions: item.permissions | 0o200),
                of: url,
                cancellation: cancellation
            )
            do {
                try remove()
                return true
            } catch {
                if item.permissions & 0o200 == 0 {
                    try? provider.setAttributes(
                        FileAttributes(permissions: item.permissions),
                        of: url,
                        cancellation: patience(with: provider)
                    )
                }
                if let flags { FileIdentity.restoreFlags(flags, of: url) }
                throw error
            }
        }
    }

    /// "Operation not permitted": what the system answers for a locked item, as opposed to a
    /// folder one has no right to change.
    static func isRefusedAsLocked(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(EPERM) }
        return (error.userInfo[NSUnderlyingErrorKey] as? (any Error)).map(isRefusedAsLocked) ?? false
    }

    // MARK: Helpers

    private func delegateOrStop() throws -> any FileJobDelegate {
        guard let delegate else { throw Cancelled() }
        return delegate
    }

    /// The job ends because of an answer (Abort, Cancel in a question) or an error it cannot
    /// go on after: the workers stop, and so does whatever waits on the job's own flag, such
    /// as a progress window that holds the job back while it is paused.
    private func halt() {
        stop.cancel()
        cancellation.cancel()
    }

    /// Counts and logs something that went wrong without a question being asked about it.
    private func note(_ verb: OperationRecord.Verb, at url: URL, _ message: String) {
        counters.withLock {
            failureCount += 1
            if failures.count < 20 { failures.append("\(display(url)): \(message)") }
        }
        record(verb, url, nil, .failed(message))
    }

    /// Runs one step; on failure asks Skip / Skip all / Retry / Abort. Used on every thread of the job.
    private func attempt(_ verb: OperationRecord.Verb, at url: URL, target: URL? = nil, _ step: () throws -> Bool)
        throws -> Bool
    {
        do {
            return try step()
        } catch is Cancelled {
            throw Cancelled()
        } catch {
            // What fails because the job is being stopped is not a question for the user.
            if isStopping { throw Cancelled() }
            counters.withLock {
                failureCount += 1
                if failures.count < 20 { failures.append("\(display(url)): \(error.localizedDescription)") }
            }
            record(verb, url, target, .failed(error.localizedDescription))
            let choice: ErrorChoice = try decisions.withLock {
                if skipAllErrors { return .skip }
                // Another worker's question may have ended the job while this one waited its turn.
                if isStopping { throw Cancelled() }
                let choice = try delegateOrStop().job(self, failedAt: url, error: error)
                if choice == .skipAll { skipAllErrors = true }
                if choice == .abort { halt() }
                return choice
            }
            switch choice {
            case .skip, .skipAll:
                record(verb, url, target, .skipped)
                return false

            case .retry: return try attempt(verb, at: url, target: target, step)
            case .abort: throw Cancelled()
            }
        }
    }

    private func checkCancelled() throws {
        if isStopping { throw Cancelled() }
    }

    private func display(_ url: URL) -> String {
        fileSystems.displayPath(url)
    }

    private func record(_ verb: OperationRecord.Verb, _ source: URL, _ target: URL?, _ status: OperationRecord.Status) {
        guard let onRecord, wantsRecord?(verb, status) ?? true else { return }
        onRecord(OperationRecord(verb, source: display(source), target: target.map(display), status: status))
    }

    // MARK: Progress

    /// A new item is being worked on.
    private func report(_ lines: [String]) {
        let due = counters.withLock { () -> Bool in
            currentLines = lines
            pendingLines = nil
            return isDue
        }
        if due { emit(force: false) }
    }

    /// The same, with the lines put together only if a report is really sent: most items of
    /// a big folder pass between two reports.
    private func report(_ lines: @escaping () -> [String]) {
        let due = counters.withLock { () -> Bool in
            pendingLines = lines
            return isDue
        }
        if due { emit(force: false) }
    }

    /// `copied`: how much of the file this flight carries has arrived so far.
    private func advance(_ flight: Flight, to copied: Int64) {
        let due = counters.withLock { () -> Bool in
            inFlightBytes += copied - flight.bytes
            flight.bytes = copied
            return isDue
        }
        if due { emit(force: false) }
    }

    /// The file of this flight is dealt with: it counts as done with its full size.
    private func land(_ flight: Flight, _ measure: Measure) {
        counters.withLock {
            inFlightBytes -= flight.bytes
            flight.bytes = 0
            done += measure
        }
    }

    private func add(_ measure: Measure) {
        counters.withLock { done += measure }
    }

    /// Whether enough time has passed for the next report. Called with `counters` held.
    private var isDue: Bool {
        guard progressInterval > 0, lastReport != 0 else { return true }
        return DispatchTime.now().uptimeNanoseconds - lastReport >= UInt64(progressInterval * 1_000_000_000)
    }

    /// Tells the delegate where the job stands. The figures are taken under `counters`, the
    /// delegate is called under `delivery` only: the reports stay in order and one at a time,
    /// and a delegate that takes its time (a paused job waits in there) keeps no counter from
    /// being updated. Called without either lock held.
    private func emit(force: Bool) {
        guard let delegate else { return }
        delivery.lock()
        defer { delivery.unlock() }
        let progress = counters.withLock { () -> JobProgress? in
            // Another thread may have reported while this one waited its turn.
            guard force || isDue else { return nil }
            lastReport = DispatchTime.now().uptimeNanoseconds
            if let pendingLines {
                currentLines = pendingLines()
                self.pendingLines = nil
            }
            return JobProgress(
                lines: currentLines,
                itemsDone: done.items,
                itemsTotal: total.items,
                bytesDone: done.bytes.addingSaturated(inFlightBytes),
                bytesTotal: total.bytes
            )
        }
        if let progress { delegate.job(self, progress: progress) }
    }

    /// Everything directly inside a directory, hidden items too, in processing order (a delete
    /// has none: nothing depends on it, and sorting a big folder by name is slow). Nil when the
    /// directory could not be read and the user chose to skip it. An entry whose name could lead
    /// out of the folder (`..`, a name with a slash: a server may send such a thing) is not
    /// returned; it is reported as an error of its own and counted in `rejected`.
    private func listing(of directory: URL, sorted: Bool = true) throws -> (items: [FileItem], rejected: Int)? {
        var items: [FileItem] = []
        let verb: OperationRecord.Verb = kind == .copy ? .copy : (isMove ? .move : .delete)
        let readable = try attempt(verb, at: directory) {
            items = try self.fileSystems.provider(for: directory)
                .list(
                    directory,
                    showHidden: true,
                    cancellation: self.cancellation
                )
            // A listing that ended because of the cancel is not the whole folder.
            try self.checkCancelled()
            return true
        }
        guard readable else { return nil }
        var rejected = 0
        if items.contains(where: { !Self.isSafeName($0.name) }) {
            for child in items where !Self.isSafeName(child.name) {
                rejected += 1
                add(Measure(items: 1))
                _ = try attempt(verb, at: directory) { throw FileJobError.unsafeName(child.name) }
            }
            items.removeAll { !Self.isSafeName($0.name) }
        }
        return (sorted ? Sorter.sorted(items, byName: \.name) : items, rejected)
    }

    /// A name that stands for one entry of its folder: not empty, not `.` or `..`, no `/`, no NUL.
    /// The kernel's rule (`PathSafety`), byte for byte.
    static func isSafeName(_ name: String) -> Bool {
        PathSafety.isSafeName(name)
    }

    /// How a target name is compared for "is it taken": a volume may fold letter case and the
    /// forms of an accented letter, and then two names that look different are one place.
    static func claimKey(_ url: URL) -> String {
        url.locationKey.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `claimKey` as a number, for remembering many targets in little memory. Two targets
    /// that fold to one place have one number; two that do not may share one, once in a blue
    /// moon, and are then taken for one place, which errs on the careful side.
    static func claimHash(_ url: URL) -> Int {
        claimKey(url).hashValue
    }

    // MARK: Counting

    /// What a source adds to the total. A folder that a move is going to rename as a whole is
    /// one item, and its contents are not walked: that would take as long as a copy's count.
    private func measureForTotal(_ url: URL, _ item: FileItem?) -> Measure {
        guard let item else { return Measure(items: 1) }
        if isMove, options.filter.isEmpty, item.isRealDirectory, willRename(item) {
            predictedRenames.insert(url.locationKey)
            return Measure(items: 1)
        }
        return measure(item)
    }

    /// Whether the system will rename the folder to its place: both on one local volume, and
    /// nothing there under that name. A wrong guess costs a count later, nothing else.
    private func willRename(_ folder: FileItem) -> Bool {
        guard folder.url.isFileURL, let target else { return false }
        let destination = destination(for: folder.url, in: target)
        guard destination.isFileURL, !destination.isSameLocation(as: folder.url),
            fileSystems.item(at: destination) == nil,
            let here = FileIdentity.device(of: folder.url.deletingLastPathComponent()),
            let there = FileIdentity.device(ofNearest: destination.deletingLastPathComponent())
        else { return false }
        return here == there
    }

    /// What the first count found for a folder, if it kept it; else the folder is walked.
    private func measuredBefore(_ item: FileItem) -> Measure {
        if let known = remembered.withLock({ measures[item.url.locationKey.hashValue] }) { return known }
        return measure(item)
    }

    /// How many folders of one level are listed side by side before their listings are added
    /// up and let go: the listings of a whole level at once could be the whole tree.
    private static let measuredAtOnce = 256

    /// Counts a tree level by level: the folders of a level are listed on all cores at once,
    /// and no call goes deeper for a folder that lies deeper, so a tree of any depth (an
    /// archive or a server may show one) costs no stack. What lies below `depthLimit` is not
    /// counted, as it is not processed.
    private func measure(_ listed: FileItem) -> Measure {
        struct Node {
            var parent: Int
            var measure: Measure
            /// The folder's place in `measures`.
            var key: Int
        }
        let top = followsLinks ? resolvingLink(listed) : listed
        guard top.isRealDirectory, !cancellation.isCancelled else { return Measure(items: 1, bytes: top.size) }
        var nodes = [Node(parent: -1, measure: Measure(items: 1), key: top.url.locationKey.hashValue)]
        var level: [(index: Int, url: URL)] = [(0, top.url)]
        var depth = 0
        while !level.isEmpty, !cancellation.isCancelled, depth <= depthLimit {
            var next: [(index: Int, url: URL)] = []
            for start in stride(from: 0, to: level.count, by: Self.measuredAtOnce) {
                if cancellation.isCancelled { break }
                let chunk = Array(level[start..<min(start + Self.measuredAtOnce, level.count)])
                autoreleasepool {
                    let listings = Parallel.map(chunk, serialBelow: 2) { folder -> [FileItem]? in
                        try? self.fileSystems.provider(for: folder.url)
                            .list(
                                folder.url,
                                showHidden: true,
                                cancellation: self.cancellation
                            )
                    }
                    for (folder, children) in zip(chunk, listings) {
                        var own = Measure()
                        for child in children ?? [] {
                            guard Self.isSafeName(child.name) else {
                                own += Measure(items: 1)
                                continue
                            }
                            // A link to a file whose size the listing brought along needs no
                            // look at the disk to be counted.
                            if followsLinks, child.isSymlink, !child.isDirectory, let size = child.linkTargetSize {
                                own += Measure(items: 1, bytes: size)
                                continue
                            }
                            let item = followsLinks ? resolvingLink(child) : child
                            if item.isRealDirectory {
                                nodes.append(
                                    Node(
                                        parent: folder.index,
                                        measure: Measure(items: 1),
                                        key: item.url.locationKey.hashValue
                                    )
                                )
                                next.append((nodes.count - 1, item.url))
                            } else {
                                own += Measure(items: 1, bytes: item.size)
                            }
                        }
                        nodes[folder.index].measure += own
                    }
                }
            }
            level = next
            depth += 1
        }
        // A folder comes after the folder it lies in: adding up from the end gives every
        // folder the sum of what is below it.
        for index in stride(from: nodes.count - 1, to: 0, by: -1) {
            nodes[nodes[index].parent].measure += nodes[index].measure
        }
        if !cancellation.isCancelled {
            remembered.withLock {
                for node in nodes {
                    let room =
                        measures.count < rememberedLimit
                        || (node.measure.items >= Self.worthKeepingPastLimit && measures.count < 2 * rememberedLimit)
                    if room { measures[node.key] = node.measure }
                }
            }
        }
        return nodes[0].measure
    }

    private static func inProcessingOrder(_ urls: [URL]) -> [URL] {
        Sorter.sorted(urls, byName: \.lastPathComponent)
    }
}

/// What identifies an entry on a local disk, so that two spellings of one place (another
/// letter case on a case-insensitive volume, `/tmp` and `/private/tmp`) are told apart from
/// two files. Anything that is not a local path has no identity and compares as different.
enum FileIdentity {
    private static func status(_ path: String, followingLinks: Bool) -> stat? {
        var info = stat()
        return (followingLinks ? stat(path, &info) : lstat(path, &info)) == 0 ? info : nil
    }

    private static func status(_ url: URL, followingLinks: Bool) -> stat? {
        url.isFileURL ? status(url.path, followingLinks: followingLinks) : nil
    }

    /// The path of the folder above, down to the root, which has none.
    private static func parent(of path: String) -> String? {
        guard path != "/", !path.isEmpty else { return nil }
        return (path as NSString).deletingLastPathComponent
    }

    /// The flags of the entry itself (the Finder's lock among them); nil when it cannot be asked.
    static func flags(of url: URL) -> UInt32? {
        status(url, followingLinks: false)?.st_flags
    }

    /// Gives an entry back the flags it had.
    static func restoreFlags(_ flags: UInt32, of url: URL) {
        guard url.isFileURL, let now = status(url, followingLinks: false), now.st_flags != flags else { return }
        lchflags(url.path, flags)
    }

    /// The volume the entry is on.
    static func device(of url: URL) -> dev_t? {
        status(url, followingLinks: true)?.st_dev
    }

    /// The volume of `url`, or of the nearest folder above it that exists.
    static func device(ofNearest url: URL) -> dev_t? {
        guard url.isFileURL else { return nil }
        var path = url.path
        // The nearest folder that is there: the root always is.
        while status(path, followingLinks: true) == nil, let above = parent(of: path) {
            path = above
        }
        return status(path, followingLinks: true)?.st_dev
    }

    /// True when both names are the same directory entry: the same file in the same folder,
    /// the names differing at most in letter case or in the form of an accented letter. Two
    /// hard links to one file are not.
    static func sameEntry(_ a: URL, _ b: URL) -> Bool {
        guard a.isFileURL, b.isFileURL,
            a.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                == b.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased(),
            let first = status(a, followingLinks: false), let second = status(b, followingLinks: false),
            first.st_dev == second.st_dev, first.st_ino == second.st_ino,
            let folderA = status(a.deletingLastPathComponent(), followingLinks: true),
            let folderB = status(b.deletingLastPathComponent(), followingLinks: true)
        else { return false }
        return folderA.st_dev == folderB.st_dev && folderA.st_ino == folderB.st_ino
    }

    /// True when `destination` is somewhere below `folder` as the disk sees it: in the folder
    /// itself or any folder inside it, whichever way the path is spelled or through whatever
    /// links it leads. Looks at the folders above `destination` that exist.
    static func isInside(_ destination: URL, folder: URL) -> Bool {
        guard destination.isFileURL, let own = status(folder, followingLinks: false) else { return false }
        var path = parent(of: destination.path)
        while let current = path {
            if let found = status(current, followingLinks: true), found.st_dev == own.st_dev, found.st_ino == own.st_ino
            {
                return true
            }
            path = parent(of: current)
        }
        return false
    }
}

/// A value behind a lock. Unchecked `Sendable`: `value` is guarded by `lock`.
final class Guarded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
