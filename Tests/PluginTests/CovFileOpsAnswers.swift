import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport

/// Answers every question of a job from lists the test fills, the last answer of a list again once it runs out, and
/// records what was asked. Any thread: everything is kept in `Shared` boxes.
internal final class CovFileOpsAnswers: FileJobDelegate, Sendable {
    /// The answers to name collisions.
    internal let conflicts = Shared<[ConflictChoice]>([.overwrite])
    /// The answers to failures.
    internal let failures = Shared<[ErrorChoice]>([.skip])
    /// The answers to deleting a folder that is not empty.
    internal let nonEmpty = Shared<[FolderDeleteChoice]>([.delete])
    /// The answers to protected items.
    internal let protections = Shared<[ProtectionChoice]>([.proceed])
    /// The answers to merging into a folder that exists.
    internal let merges = Shared<[MergeChoice]>([.merge])
    /// The answers to going into another volume.
    internal let volumes = Shared<[ProtectionChoice]>([.skip])
    /// What was asked, one line per question.
    internal let asked = Shared<[String]>([])
    /// Runs with every report of progress.
    internal let onProgress = Shared<(@Sendable (FileJob, JobProgress) -> Void)?>(nil)

    /// Drops the report, after the hook has seen it.
    internal func job(_ job: FileJob, progress: JobProgress) {
        onProgress.value?(job, progress)
    }

    /// The next answer to a collision.
    internal func job(_: FileJob, conflictAt target: FileItem, source _: FileItem) -> ConflictChoice {
        next(conflicts, "conflict: \(target.name)")
    }

    /// The next answer to a failure.
    internal func job(_: FileJob, failedAt url: URL, error: any Error) -> ErrorChoice {
        next(failures, "failed: \(url.lastPathComponent): \(error.localizedDescription)")
    }

    /// The next answer to a folder that is not empty.
    internal func job(_: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice {
        next(nonEmpty, "not empty: \(directory.lastPathComponent)")
    }

    /// The next answer to a protected item.
    internal func job(_: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice {
        next(protections, "protected: \(question.reason) \(question.item.name)")
    }

    /// The next answer to a merge.
    internal func job(_: FileJob, mergeInto existing: FileItem, source _: FileItem) -> MergeChoice {
        next(merges, "merge: \(existing.name)")
    }

    /// The next answer to another volume.
    internal func job(_: FileJob, crossVolumeAt folder: FileItem, purpose _: ProtectionQuestion.Purpose)
        -> ProtectionChoice
    {
        next(volumes, "volume: \(folder.name)")
    }

    private func next<Answer>(_ answers: Shared<[Answer]>, _ question: String) -> Answer {
        asked.modify { $0.append(question) }
        var answer: Answer?
        answers.modify { list in
            answer = list.count > 1 ? list.removeFirst() : list.first
        }
        guard let answer else {
            preconditionFailure("no answer for \(question)")
        }
        return answer
    }

    deinit {
        // Nothing to release.
    }
}
