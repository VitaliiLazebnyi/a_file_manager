import AFMContracts
import AFMKernel
import Foundation

/// Runs the work of a job at once, on the calling thread, and keeps its completion until
/// `deliver()`: the time in which the user goes on working while a job is under way.
internal final class P2DeferredJobs: JobService {
    /// What the work of a job is given: a flag nobody sets, and questions answered on the calling thread.
    internal final class Monitor: JobMonitor, Sendable {
        /// The job's flag; nothing sets it.
        internal let cancellation = CancellationFlag()

        /// Drops the report: nobody shows progress here.
        internal func report(_: JobProgress) {
            // Nothing shows progress.
        }
        /// Asks `question` on the calling thread, which is the main one.
        internal func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
            // The work runs on the calling thread, the main one.
            MainActor.assumeIsolated(question)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Never true: the work is done before `run` returns.
    internal private(set) var isBusy = false
    private var pending: [() -> Void] = []
    /// The title of every job that was run, in that order.
    internal private(set) var titles: [String] = []
    /// Called after each job's work, before its completion is kept.
    internal var afterWork: (() -> Void)?

    /// Notes the title, does the work at once and keeps the completion for `deliver()`.
    internal func run<Result: Sendable>(
        title: String,
        work: @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        titles.append(title)
        let result = work(Monitor())
        afterWork?()
        pending.append { completion(result) }
    }

    /// Runs the completions that wait, and those they start.
    internal func deliver() {
        while !pending.isEmpty { pending.removeFirst()() }
    }

    deinit {
        // Nothing to release.
    }
}
