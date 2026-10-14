import AFMKernel
import FileOperationsPlugin
import Foundation

/// Answers like a user who says yes to everything, through the monitor (as JobBridge does),
/// and checks that the progress never goes backwards.
///
/// Unchecked: the job's threads, the main thread and a timer use it; every `var` is only read and
/// written under `lock`.
internal final class Recorder: FileJobDelegate, @unchecked Sendable {
    /// Where the progress goes and the questions are asked.
    internal let monitor: any JobMonitor
    /// The run's name, for the violations.
    internal let label: String
    /// Guards every `var`.
    private let lock = NSLock()
    /// The progress reported last.
    private var last: JobProgress?
    /// How many progress reports came.
    private var reportCount = 0
    /// How many reports went backwards.
    private var backwards = 0
    /// The errors the job asked about.
    private var errorList: [String] = []
    /// How many questions the job asked.
    private var questions = 0
    /// What an error is answered with.
    private var answer: ErrorChoice = .skip

    /// How many progress reports came.
    internal var reports: Int {
        lock.withLock { reportCount }
    }

    /// The errors the job asked about, as "name: message".
    internal var errors: [String] {
        lock.withLock { errorList }
    }

    /// The progress reported last.
    internal var lastProgress: JobProgress? {
        lock.withLock { last }
    }

    /// What an error is answered with (Skip at first).
    internal var errorAnswer: ErrorChoice {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }

    /// A delegate for the job that runs with `monitor`, called `label` in the findings.
    internal init(monitor: any JobMonitor, label: String) {
        self.monitor = monitor
        self.label = label
    }

    /// Checks the report against the one before and passes it on to the monitor.
    internal func job(_: FileJob, progress: JobProgress) {
        lock.lock()
        reportCount += 1
        if let last, progress.itemsDone < last.itemsDone || progress.bytesDone < last.bytesDone {
            backwards += 1
            if backwards <= 3 {
                Findings.shared.violation(
                    "progress went backwards",
                    "\(label): items \(last.itemsDone)->\(progress.itemsDone) bytes \(last.bytesDone)->"
                        + "\(progress.bytesDone) totals \(progress.itemsTotal)/\(progress.bytesTotal)"
                )
            }
        }
        // Changed totals are not a violation by themselves (totals may be corrected).
        if progress.itemsDone > progress.itemsTotal || progress.bytesDone > progress.bytesTotal {
            Findings.shared.violation(
                "progress beyond total",
                "\(label): items \(progress.itemsDone)/\(progress.itemsTotal) bytes "
                    + "\(progress.bytesDone)/\(progress.bytesTotal)"
            )
        }
        last = progress
        lock.unlock()
        monitor.report(progress)
    }

    /// Overwrites all.
    internal func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice {
        lock.withLock { questions += 1 }
        return monitor.ask { .overwriteAll }
    }

    /// Notes the error and answers with `errorAnswer`.
    internal func job(_: FileJob, failedAt url: URL, error: any Error) -> ErrorChoice {
        let choice: ErrorChoice = lock.withLock {
            questions += 1
            errorList.append("\(url.lastPathComponent): \(error.localizedDescription)")
            return answer
        }
        return monitor.ask { choice }
    }

    /// Deletes all.
    internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice {
        lock.withLock { questions += 1 }
        return monitor.ask { .all }
    }

    /// Goes ahead with all.
    internal func job(_: FileJob, confirm _: ProtectionQuestion) -> ProtectionChoice {
        monitor.ask { .all }
    }

    /// Merges all.
    internal func job(_: FileJob, mergeInto _: FileItem, source _: FileItem) -> MergeChoice {
        monitor.ask { .mergeAll }
    }

    deinit {
        // Nothing to release.
    }
}
