public import AFMKernel
import Foundation

/// Runs each job on the calling thread, like `ImmediateJobService`, and presses its Cancel
/// button at a chosen moment: before it starts, when it asks a question, or when it reports its
/// progress. With `held`, a job waits until the test lets it run, so that what is refused while
/// a job runs can be tried.
///
/// Main thread only.
public final class CancellingJobService: JobService, ShellServices {
    /// When Cancel is pressed.
    public enum Moment: Sendable {
        /// Before the work starts.
        case atStart
        /// When the work asks its `n`-th question (from 1), after the answer.
        case afterQuestion(Int)
        /// When the work reports its progress for the `n`-th time (from 1).
        case atReport(Int)
        /// Never: the job runs as it would.
        case never
        /// The job waits until `runHeld()`, then runs as it would.
        case held
    }

    /// The monitor a job reports to. Unchecked: the counts are guarded by `lock`.
    private final class Monitor: JobMonitor, @unchecked Sendable {
        let cancellation = CancellationFlag()
        private let moment: Moment
        private let lock = NSLock()
        private var questions = 0
        private var reports = 0

        init(_ moment: Moment) {
            self.moment = moment
            if case .atStart = moment { cancellation.cancel() }
        }

        func report(_: JobProgress) {
            let count = lock.withLock {
                reports += 1
                return reports
            }
            if case .atReport(let wanted) = moment, wanted == count { cancellation.cancel() }
        }

        /// Asked on the thread of the work, as `ImmediateJobService` does: the main thread waits for it.
        func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
            let answer =
                Thread.isMainThread
                ? MainActor.assumeIsolated(question)
                : withoutActuallyEscaping(question) { unsafeBitCast($0, to: (@Sendable () -> Answer).self)() }
            let count = lock.withLock {
                questions += 1
                return questions
            }
            if case .afterQuestion(let wanted) = moment, wanted == count { cancellation.cancel() }
            return answer
        }

        deinit {
            // Nothing to release.
        }
    }

    /// When the next jobs are cancelled.
    public var moment: Moment
    /// True only while a job runs, which is inside `run`.
    public private(set) var isBusy = false
    /// The titles of every job that was run, in order.
    public private(set) var titles: [String] = []
    /// The panels of the kernel this serves.
    public let panels: any PanelSet
    private var heldJobs: [@MainActor () -> Void] = []

    /// How many jobs wait for `runHeld()`.
    public var heldCount: Int { heldJobs.count }

    /// The job service, which is this.
    public var jobs: any JobService { self }

    /// A service that cancels its jobs at `moment`, for a kernel with these panels.
    public init(moment: Moment, panels: any PanelSet) {
        self.moment = moment
        self.panels = panels
    }

    /// Runs `work` on this thread and calls `completion` with its result, before returning; a
    /// held job does so in `runHeld()`.
    public func run<Result: Sendable>(
        title: String,
        work: @escaping @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        titles.append(title)
        isBusy = true
        let job: @MainActor () -> Void = { [moment] in
            let result = work(Monitor(moment))
            self.isBusy = false
            completion(result)
        }
        if case .held = moment { heldJobs.append(job) } else { job() }
    }

    /// Runs the jobs that were held, in order.
    public func runHeld() {
        let jobs = heldJobs
        heldJobs = []
        jobs.forEach { $0() }
    }

    deinit {
        // Nothing to release.
    }
}
