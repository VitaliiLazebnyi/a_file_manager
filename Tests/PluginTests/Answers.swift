import AFMKernel
import FileOperationsPlugin
import Foundation

/// Answers a job's questions with fixed choices and records what was asked.
internal final class Answers: FileJobDelegate {
    /// The answer to every question about a name that is taken in the target.
    internal var conflict: ConflictChoice = .overwrite
    /// The answer to every question about deleting a folder that is not empty.
    internal var folderDelete: FolderDeleteChoice = .delete
    /// The answer to every error.
    internal var failure: ErrorChoice = .skip
    /// When set, the job is cancelled as soon as a report has this many bytes done.
    internal var cancelAtBytes: Int64?
    /// When set, the job is cancelled as soon as a report has this many items done.
    internal var cancelAtItems: Int?
    /// The names of the targets the job asked about, in that order.
    internal var conflicts: [String] = []
    /// The texts of the errors the job reported, in that order.
    internal var errors: [String] = []
    /// The names of the folders the job asked about deleting with their contents.
    internal var nonEmptyQuestions: [String] = []
    /// Every progress report, in that order.
    internal var progress: [JobProgress] = []

    /// Notes the report, and cancels the job when one of the limits is reached.
    internal func job(_ job: FileJob, progress: JobProgress) {
        self.progress.append(progress)
        if let cancelAtBytes, progress.bytesDone >= cancelAtBytes { job.cancel() }
        if let cancelAtItems, progress.itemsDone >= cancelAtItems { job.cancel() }
    }

    /// Notes the name of the target and answers with `conflict`.
    internal func job(_: FileJob, conflictAt target: FileItem, source _: FileItem) -> ConflictChoice {
        conflicts.append(target.name)
        return conflict
    }

    /// Notes the error's text and answers with `failure`.
    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        errors.append(error.localizedDescription)
        return failure
    }

    /// Notes the folder's name and answers with `folderDelete`.
    internal func job(_: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice {
        nonEmptyQuestions.append(directory.lastPathComponent)
        return folderDelete
    }

    /// Runs a job on the calling thread with these answers, and returns its result.
    @discardableResult
    internal func run(
        _ kind: JobKind,
        _ sources: [URL],
        to target: TargetSpec?,
        fileSystems: FileSystemRegistry
    ) -> JobResult {
        let job = FileJob(kind: kind, sources: sources, target: target, fileSystems: fileSystems)
        job.delegate = self
        return job.run()
    }

    deinit {
        // Nothing to release.
    }
}
