import AFMKernel
import Foundation

@testable import FileOperationsPlugin

/// Answers a job's questions and keeps what it was told, from whatever thread.
internal final class P2Replies: FileJobDelegate {
    private let lock = NSLock()
    private var messages: [String] = []
    private var reports: [(lines: [String], tag: Int)] = []
    /// The answer to every conflict; Overwrite unless the test says otherwise.
    internal var conflict: ConflictChoice = .overwrite
    /// The answer to every question about merging two folders; Merge unless the test says otherwise.
    internal var merge: MergeChoice = .merge
    /// Asked at every report; what it answers is kept with the report.
    internal var tag: (() -> Int)?

    /// The errors the job reported, in that order.
    internal var errors: [String] { lock.withLock { messages } }
    /// The lines of every progress report, each with what `tag` answered then (0 without `tag`).
    internal var progress: [(lines: [String], tag: Int)] { lock.withLock { reports } }

    /// Keeps the report's lines with the answer of `tag`.
    internal func job(_: FileJob, progress: JobProgress) {
        let answer = tag?() ?? 0
        lock.withLock { reports.append((progress.lines, answer)) }
    }
    /// Answers with `conflict`.
    internal func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { conflict }
    /// Keeps the error's text and skips the item.
    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock { messages.append(error.localizedDescription) }
        return .skip
    }
    /// Deletes a folder that is not empty.
    internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }
    /// Answers with `merge`.
    internal func job(_: FileJob, mergeInto _: FileItem, source _: FileItem) -> MergeChoice { merge }

    deinit {
        // Nothing to release.
    }
}
