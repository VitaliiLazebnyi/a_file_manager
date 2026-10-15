import AFMKernel
import Foundation

/// The monitor of a job the test runs itself: its flag can be set, its reports are counted, and
/// it asks nothing.
///
/// `reported` is guarded by `lock`.
internal final class CoverageViewerJobMonitor: JobMonitor, @unchecked Sendable {
    /// The job's stop.
    internal let cancellation = CancellationFlag()
    private let lock = NSLock()
    private var reported = 0

    /// How many reports came.
    internal var reports: Int {
        lock.lock()
        defer { lock.unlock() }
        return reported
    }

    /// Counts the report.
    internal func report(_: JobProgress) {
        lock.lock()
        reported += 1
        lock.unlock()
    }

    /// Asks on the main thread, where the tests run.
    internal func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
        MainActor.assumeIsolated(question)
    }

    deinit {
        // Nothing to release.
    }
}
