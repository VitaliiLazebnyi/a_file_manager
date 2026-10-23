import AFMKernel
import FileOperationsPlugin
import Foundation

/// Answers `retry` the first time a step fails and `skip` afterwards.
internal final class RetryOnce: FileJobDelegate {
    /// Guards `errors`: the job may ask from its worker threads.
    private let lock = NSLock()

    /// The messages of the failures the job asked about, in order.
    internal private(set) var errors: [String] = []

    /// Ignores progress.
    internal func job(_: FileJob, progress _: JobProgress) {
        // Progress is not looked at.
    }

    /// Overwrites every existing name.
    internal func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { .overwrite }

    /// Records the failure; retries the first and skips the rest.
    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock {
            errors.append(error.localizedDescription)
            return errors.count == 1 ? .retry : .skip
        }
    }

    /// Deletes non-empty folders without asking.
    internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }

    deinit {
        // Nothing to release.
    }
}
