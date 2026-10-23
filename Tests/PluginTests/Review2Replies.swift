import AFMKernel
import FileOperationsPlugin
import Foundation

/// Answers a job's questions with fixed choices, from whatever thread they come.
///
/// Unchecked: what it records is guarded by `lock`; the choices are set by the test before use.
internal final class Review2Replies: FileJobDelegate, @unchecked Sendable {
    private let lock = NSLock()
    /// The texts of the errors the job reported, in that order.
    internal private(set) var errors: [String] = []
    /// The names of the targets the job asked about, in that order.
    internal private(set) var conflicts: [String] = []
    /// The names of the folders on another volume the job asked about entering.
    internal private(set) var volumes: [String] = []
    /// How many times the job asked about a locked item.
    internal private(set) var locked = 0
    /// The answer to every question about a name that is taken in the target; Overwrite at first.
    internal var conflict = ConflictChoice.overwrite
    /// The answers to the errors in turn, the last one for the rest; Skip at first.
    internal var failures: [ErrorChoice] = [.skip]
    /// The answer to every question about entering another volume; Skip at first.
    internal var volume = ProtectionChoice.skip

    /// Replies that overwrite, skip errors and do not enter other volumes until the test sets other choices.
    internal init() {
        // The choices start as declared.
    }

    /// Ignores the report: these tests look at what the job did, not at its progress.
    internal func job(_: FileJob, progress _: JobProgress) {
        // Nothing to note.
    }

    /// Notes the name of the target and answers with `conflict`.
    internal func job(_: FileJob, conflictAt target: FileItem, source _: FileItem) -> ConflictChoice {
        lock.withLock { conflicts.append(target.name) }
        return conflict
    }

    /// Notes the error's text and answers with the next of `failures`.
    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock {
            errors.append(error.localizedDescription)
            return failures.count > 1 ? failures.removeFirst() : failures[0]
        }
    }

    /// Always lets a folder that is not empty be deleted.
    internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }

    /// Counts the questions about locked items and lets every protected item be changed.
    internal func job(_: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice {
        if question.reason == .locked { lock.withLock { locked += 1 } }
        return .proceed
    }

    /// Notes the folder's name and answers with `volume`.
    internal func job(_: FileJob, crossVolumeAt folder: FileItem, purpose _: ProtectionQuestion.Purpose)
        -> ProtectionChoice
    {
        lock.withLock { volumes.append(folder.name) }
        return volume
    }

    deinit {
        // Nothing to release.
    }
}
