public import AFMKernel
import Foundation

/// Runs each job at once on the calling thread; `run` returns when the job is done.
///
/// Main thread only.
public final class ImmediateJobService: JobService {
    /// The monitor a job reports to.
    ///
    /// Unchecked: the reports are guarded by `lock`.
    private final class Monitor: JobMonitor, @unchecked Sendable {
        let cancellation = CancellationFlag()
        private let lock = NSLock()
        private var all: [JobProgress] = []

        var reports: [JobProgress] { lock.withLock { all } }

        func report(_ progress: JobProgress) { lock.withLock { all.append(progress) } }

        /// The job runs inside `run` on the main thread, which waits there until the job is done.
        ///
        /// A job may spread its work over threads of its own; a question from one of them is asked on that thread, as
        /// the waiting main thread would ask it (jobs ask one question at a time). Hopping to the main thread would
        /// wait for ever.
        func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
            if Thread.isMainThread {
                return MainActor.assumeIsolated(question)
            }
            return withoutActuallyEscaping(question) { unsafeBitCast($0, to: (@Sendable () -> Answer).self)() }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// True only while a job runs, which is inside `run`.
    public private(set) var isBusy = false
    /// The titles of every job that was run, in order.
    public private(set) var titles: [String] = []
    /// Every progress report of every job, in order.
    public private(set) var reports: [JobProgress] = []

    /// A service that has run nothing yet.
    public init() {
        // Nothing has run yet.
    }

    /// Runs `work` on this thread, records its title and reports, then calls `completion` with
    /// its result, all before returning.
    @preconcurrency
    public func run<Result: Sendable>(
        title: String,
        work: @Sendable (any JobMonitor) -> Result,
        completion: @MainActor (Result) -> Void
    ) {
        titles.append(title)
        let monitor = Monitor()
        isBusy = true
        let result = work(monitor)
        isBusy = false
        reports += monitor.reports
        completion(result)
    }

    deinit {
        // Nothing to release.
    }
}
