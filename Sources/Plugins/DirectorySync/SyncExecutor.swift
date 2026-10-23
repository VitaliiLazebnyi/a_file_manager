public import AFMKernel
public import Foundation

/// Carries out a plan through the file-system providers, so it works between any two file
/// systems (spec 09 › The "Synchronize" dialog and the run).
///
/// Right-to-left copies run first, then left-to-right, then the deletions.
///
/// **Threading.** `run` blocks and belongs on a job's thread; the three callbacks are called
/// on that thread and may block while the user decides. `cancellation` may be set from any
/// thread. A file that replaces another is written next to it under a temporary name and
/// moved over it, so an interrupted copy never leaves a half-written target.
///
/// Unchecked: it is handed to the job's thread before `run` and used there alone; only
/// `cancellation`, which is safe from any thread, is touched from elsewhere.
public final class SyncExecutor: @unchecked Sendable {
    /// Thrown where the user or the cancel stops the run.
    internal struct Cancelled: Error {}

    /// A folder whose date and metadata are set at the end of the run.
    internal struct FolderDate {
        /// The folder that was created.
        internal var url: URL
        /// The date it is to carry.
        internal var modified: Date
        /// The folder it is a copy of, whose metadata it takes.
        internal var source: URL
        /// The file system it was created on.
        internal var provider: any FileSystemProvider
    }

    /// What is to be done.
    private let plan: SyncPlan
    /// The directions and the boxes of the Synchronize dialog.
    internal let options: SyncRunOptions
    /// The file systems both sides are reached through.
    internal let fileSystems: FileSystemRegistry
    /// Set from any thread to stop the run after the item at hand.
    internal let cancellation: CancellationFlag

    /// Asked when a copy would replace `target`, if overwrites are to be confirmed.
    public var onOverwrite: (_ target: FileItem, _ copy: SyncPlan.Copy) -> SyncOverwriteAnswer = { _, _ in .overwrite }
    /// Asked when an item could not be copied or deleted.
    public var onError: (_ url: URL, _ error: any Error) -> SyncErrorAnswer = { _, _ in .skip }
    /// Told how far the run is, before each item and while a file is copied.
    public var onProgress: ((JobProgress) -> Void)?

    /// What the run did so far.
    internal var outcome = SyncOutcome()
    /// "Overwrite All" was answered.
    internal var overwriteAll = false
    /// "Skip All" was answered to an overwrite.
    internal var skipAllExisting = false
    /// "Skip All" was answered to an error.
    private var skipAllErrors = false
    /// The items done, for the progress.
    internal var itemsDone = 0
    /// The items of the run, for the progress.
    internal var itemsTotal = 0
    /// The bytes of the copies done, for the progress.
    internal var bytesDone: Int64 = 0
    /// The bytes of all the copies, for the progress.
    internal var bytesTotal: Int64 = 0
    /// The folders whose contents changed, by location.
    internal var changed: [String: URL] = [:]
    /// The target folders already known to be there, by location.
    internal var knownDirectories: Set<String> = []
    /// The folders created, whose dates are set last.
    internal var directoryDates: [FolderDate] = []
    /// The roots of the file systems with deferred writes that something was written to, by
    /// location, still to be committed.
    internal var uncommitted: [String: (provider: any FileSystemProvider, root: URL)] = [:]
    /// What the progress window says about the item being worked on.
    internal var currentLines: [String] = []

    /// An executor of `plan` by `options` through `fileSystems`, stopped by `cancellation`.
    public init(
        plan: SyncPlan,
        options: SyncRunOptions,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag()
    ) {
        self.plan = plan
        self.options = options
        self.fileSystems = fileSystems
        self.cancellation = cancellation
    }

    /// Carries out the plan: the copies of both directions, then the deletions; blocks until done.
    public func run() -> SyncOutcome {
        let toLeft = options.copyToLeft ? plan.toLeft : []
        let toRight = options.copyToRight ? plan.toRight : []
        let deletions = (options.deleteLeft ? plan.deleteLeft : []) + (options.deleteRight ? plan.deleteRight : [])
        itemsTotal = toLeft.count + toRight.count + deletions.count
        bytesTotal = (toLeft + toRight).reduce(Int64(0)) { total, copy in total.addingSaturated(copy.size) }
        if copy([("Right -> Left", toLeft), ("Left -> Right", toRight)]), delete(deletions),
            let root = options.removeEmptyDirectoriesBelow
        {
            removeEmptyDirectories(below: root, isRoot: true)
        }
        // Folders get their dates last: copying into a folder changes its date. What they
        // carry besides (tags, flags, a lock) comes after that, as a lock would stop the date.
        for entry in directoryDates {
            try? entry.provider.setAttributes(FileAttributes(modified: entry.modified), of: entry.url)
            try? entry.provider.copyMetadata(from: entry.source, to: entry.url)
        }
        _ = commitWrites()
        outcome.wasCancelled = outcome.wasCancelled || cancellation.isCancelled
        outcome.changedDirectories = Array(changed.values)
        return outcome
    }

    /// Makes the copies of each pass, under its caption; false when the run is to stop.
    private func copy(_ passes: [(caption: String, copies: [SyncPlan.Copy])]) -> Bool {
        for (caption, copies) in passes {
            for (index, copy) in copies.enumerated() {
                let lines = [
                    "\(caption)  (\(index + 1) / \(copies.count))",
                    "From: " + fileSystems.displayPath(copy.source),
                    "To: " + fileSystems.displayPath(copy.target)
                ]
                guard step(copy.target, lines: lines, { try self.perform(copy) }) else {
                    return false
                }
                bytesDone = bytesDone.addingSaturated(copy.size)
            }
        }
        return true
    }

    /// Makes the deletions, once what was written is durable; false when the run is to stop.
    private func delete(_ deletions: [SyncPlan.Deletion]) -> Bool {
        // What was written must be where it belongs before anything is deleted.
        if !deletions.isEmpty, !commitWrites() {
            return false
        }
        // Files go before the folders that hold them, the deepest folders first.
        let ordered =
            deletions.filter { deletion in !deletion.isDirectory }
            + deletions.filter(\.isDirectory)
            .sorted { first, second in first.url.pathComponents.count > second.url.pathComponents.count }
        for deletion in ordered {
            let lines = ["Delete: " + fileSystems.displayPath(deletion.url)]
            guard step(deletion.url, lines: lines, { try self.perform(deletion) }) else {
                return false
            }
        }
        return true
    }

    /// Does one item with the user's say on failures.
    ///
    /// Returns false when the run is to stop.
    private func step(_ url: URL, lines: [String], _ work: () throws -> Bool) -> Bool {
        defer { itemsDone += 1 }
        // Tried again for as long as the user asks for it, unless the run is cancelled.
        while !cancellation.isCancelled {
            currentLines = lines
            onProgress?(
                JobProgress(
                    lines: lines,
                    itemsDone: itemsDone,
                    itemsTotal: itemsTotal,
                    bytesDone: bytesDone,
                    bytesTotal: bytesTotal
                )
            )
            do {
                if try work() {
                    let folder = url.deletingLastPathComponent()
                    changed[folder.locationKey] = folder
                } else {
                    outcome.skipped += 1
                }
                return true
            } catch is Cancelled {
                outcome.wasCancelled = true
                return false
            } catch {
                outcome.errors.append("\(fileSystems.displayPath(url)): \(error.localizedDescription)")
                outcome.skipped += 1
                if skipAllErrors {
                    return true
                }
                switch onError(url, error) {
                case .retry:
                    outcome.errors.removeLast()
                    outcome.skipped -= 1

                case .skip:
                    return true

                case .skipAll:
                    skipAllErrors = true
                    return true

                case .cancel:
                    outcome.wasCancelled = true
                    return false
                }
            }
        }
        return false
    }
}
