import AFMKernel
import Foundation

/// A job monitor for work that runs on the main thread: its questions are asked at once, its reports are dropped.
internal final class CovFileOpsMonitor: JobMonitor, Sendable {
    /// The job's flag; a test sets it to cancel.
    internal let cancellation = CancellationFlag()

    /// Drops the report.
    internal func report(_: JobProgress) {
        // Nothing shows progress here.
    }

    /// Asks on the calling thread, which is the main one.
    internal func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
        MainActor.assumeIsolated(question)
    }

    deinit {
        // Nothing to release.
    }
}
