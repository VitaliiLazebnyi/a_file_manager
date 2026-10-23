public import AFMKernel
import Foundation

/// A job service for the paths a job takes when it is cancelled or still running: in the mode
/// `.cancelled` each job runs at once on the calling thread with its flag already set; in the
/// mode `.background` it runs on a thread of its own, its completion comes later on the main
/// thread, and the test can set its flag while it runs.
///
/// Main thread only; the monitors are used from the jobs' threads.
public final class CoverageSmallJobs: JobService {
    /// How the jobs run.
    public enum Mode {
        /// At once, on the calling thread, with the flag set before the work starts.
        case cancelled
        /// At once, on the calling thread; from the job numbered `first` on (0 is the first
        /// job), with the flag set before the work starts.
        case cancelledFrom(first: Int)
        /// On a thread of its own; the completion is queued on the main thread.
        case background
    }

    /// The monitor a job reports to; questions are asked on the main thread.
    ///
    /// Unchecked: the reports are guarded by `lock`.
    private final class Monitor: JobMonitor, @unchecked Sendable {
        let cancellation = CancellationFlag()
        private let lock = NSLock()
        private var all: [JobProgress] = []
        /// Counts the reports of every job of the service as they come.
        private let counter: Shared<Int>

        var reports: [JobProgress] { lock.withLock { all } }

        init(counting counter: Shared<Int>) {
            self.counter = counter
        }

        func report(_ progress: JobProgress) {
            lock.withLock { all.append(progress) }
            counter.modify { $0 += 1 }
        }

        func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
            if Thread.isMainThread {
                return MainActor.assumeIsolated(question)
            }
            return DispatchQueue.main.sync { MainActor.assumeIsolated(question) }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// How the next jobs run.
    public var mode: Mode
    /// The titles of every job that was started, in order.
    public private(set) var titles: [String] = []
    /// The flags of every job that was started, in order: setting one cancels its job.
    public private(set) var flags: [CancellationFlag] = []
    /// How many jobs have started and not yet completed.
    public private(set) var running = 0
    /// Every progress report of the jobs that completed, in order.
    public private(set) var reports: [JobProgress] = []
    /// How many progress reports the jobs made so far, running ones included; from any thread.
    nonisolated public let reportCount = Shared(0)
    /// The flags of every job started so far, for `cancelAll` from any thread.
    nonisolated private let started = Shared<[CancellationFlag]>([])

    /// True while a job runs.
    public var isBusy: Bool { running > 0 }

    /// A service that has run nothing yet.
    public init(_ mode: Mode) {
        self.mode = mode
    }

    /// Runs `work` as `mode` says and hands its result to `completion` on the main thread.
    @preconcurrency
    public func run<Result: Sendable>(
        title: String,
        work: @escaping @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        titles.append(title)
        let monitor = Monitor(counting: reportCount)
        flags.append(monitor.cancellation)
        started.modify { $0.append(monitor.cancellation) }
        running += 1
        switch mode {
        case .cancelled:
            monitor.cancellation.cancel()
            let result = work(monitor)
            finish(monitor, result, completion)

        case .cancelledFrom(let first):
            if titles.count > first {
                monitor.cancellation.cancel()
            }
            let result = work(monitor)
            finish(monitor, result, completion)

        case .background:
            // Made on the main thread and used there only: the job's thread only carries them.
            let onMain = Handover((service: self, completion: completion))
            OtherThread.start {
                let result = work(monitor)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onMain.value.service.finish(monitor, result, onMain.value.completion) }
                }
            }
        }
    }

    /// Cancels every job started so far; from any thread (a file system's hook, say).
    nonisolated public func cancelAll() {
        for flag in started.value {
            flag.cancel()
        }
    }

    /// Waits on the main thread, letting it run what was queued for it, until `condition`
    /// holds; false when it still does not after `Wait.ceiling`.
    public func settle(until condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            guard Date() < end else {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    private func finish<Result>(_ monitor: Monitor, _ result: Result, _ completion: @MainActor (Result) -> Void) {
        running -= 1
        reports += monitor.reports
        completion(result)
    }

    deinit {
        // Nothing to release.
    }
}
