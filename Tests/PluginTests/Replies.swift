import AFMKernel
import FileOperationsPlugin
import Foundation

/// Answers a job's questions from scripts and records what was asked.
///
/// Safe to call from the job's worker threads.
internal final class Replies: FileJobDelegate {
    private let lock = NSLock()
    private var conflictScript: [ConflictChoice]
    private var asked: [String] = []
    private var reports: [JobProgress] = []
    private var failureTexts: [String] = []
    private var protectionAsked: [String] = []
    private var mergeAsked: [String] = []
    /// The answer to every error.
    internal var failure = ErrorChoice.skip
    /// The answer to every question about a read-only, hidden or locked item.
    internal var protection = ProtectionChoice.proceed
    /// The answer to every question about merging into an existing folder.
    internal var merge = MergeChoice.merge
    /// When set, the job is cancelled as soon as a report has this many items done.
    internal var cancelAtItems: Int?
    /// When set, the job is cancelled as soon as a report has this many bytes done.
    internal var cancelAtBytes: Int64?

    /// The names of the targets the job asked about, in that order.
    internal var conflicts: [String] { lock.withLock { asked } }
    /// Every progress report, in the order it came.
    internal var progress: [JobProgress] { lock.withLock { reports } }
    /// The texts of the errors the job reported, in that order.
    internal var errors: [String] { lock.withLock { failureTexts } }
    /// The questions about protected items, each as "reason purpose name".
    internal var protections: [String] { lock.withLock { protectionAsked } }
    /// The names of the folders the job asked about merging into.
    internal var merges: [String] { lock.withLock { mergeAsked } }

    /// The conflict answers in order; the last one is repeated.
    internal init(_ conflicts: ConflictChoice...) {
        conflictScript = conflicts.isEmpty ? [.overwrite] : conflicts
    }

    /// Notes the report, and cancels the job when one of the limits is reached.
    internal func job(_ job: FileJob, progress: JobProgress) {
        lock.withLock { reports.append(progress) }
        if let cancelAtItems, progress.itemsDone >= cancelAtItems { job.cancel() }
        if let cancelAtBytes, progress.bytesDone >= cancelAtBytes { job.cancel() }
    }

    /// Notes the name of the target and answers with the next conflict answer of the script.
    internal func job(_: FileJob, conflictAt target: FileItem, source _: FileItem) -> ConflictChoice {
        lock.withLock {
            asked.append(target.name)
            return conflictScript.count > 1 ? conflictScript.removeFirst() : conflictScript[0]
        }
    }

    /// Notes the error's text and answers with `failure`.
    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock { failureTexts.append(error.localizedDescription) }
        return failure
    }

    /// Always lets a folder that is not empty be deleted.
    internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }

    /// Notes the question and answers with `protection`.
    internal func job(_: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice {
        lock.withLock { protectionAsked.append("\(question.reason) \(question.purpose) \(question.item.name)") }
        return protection
    }

    /// Notes the name of the existing folder and answers with `merge`.
    internal func job(_: FileJob, mergeInto existing: FileItem, source _: FileItem) -> MergeChoice {
        lock.withLock { mergeAsked.append(existing.name) }
        return merge
    }

    /// Runs a job on the calling thread with these replies, and returns its result; `configure`
    /// sets its options first.
    @discardableResult
    internal func run(
        _ kind: JobKind,
        _ sources: [URL],
        to target: TargetSpec?,
        fileSystems: FileSystemRegistry,
        configure: ((FileJob) -> Void)?
    ) -> JobResult {
        let job = FileJob(kind: kind, sources: sources, target: target, fileSystems: fileSystems)
        job.delegate = self
        configure?(job)
        // The job holds its delegate weakly.
        return withExtendedLifetime(self) { job.run() }
    }

    deinit {
        // Nothing to release.
    }
}
