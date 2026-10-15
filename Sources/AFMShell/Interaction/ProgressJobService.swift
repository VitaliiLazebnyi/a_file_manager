import AFMContracts
import AFMKernel
import AppKit

/// Runs the plugins' long work in the background, one job after another, with a progress window.
///
/// Jobs run in the order they were handed in (spec 07 › Progress window and job sequence). The
/// user can pause the running job, cancel it, and send the progress window to the background
/// (spec 07 › Routes into the background).
///
/// **Threading.** The service, its queue and its window belong to the main thread. A job's
/// `work` runs on a thread of its own (not on the system's shared pool, where it might never
/// get a thread, or keep one for good) and talks back only through its `JobMonitor`. Its
/// completion comes to the main thread through the run loop (`MainLoop`), so it may show a
/// dialog. Pausing holds the job's thread inside `JobMonitor.report`, so it works with every
/// job that reports its progress, and a paused job still answers to Cancel. A job must
/// therefore not hold, while it reports, a lock that the main thread or its own `ask`
/// questions take: the report may stand still for as long as the user pleases.
///
/// **A job that does not stop.** Cancel only asks the work to stop; work that waits in the
/// system (a write to a share that has stopped answering) cannot be made to. After
/// `patience` the user is asked whether to go on waiting. If not, the job is left behind:
/// the queue moves on and commands are free again, while the job's thread ends whenever the
/// system lets it, and its completion runs then.
///
/// **In the background** only the window changes: the sheet that covers the main window
/// becomes a small window of its own, so the panels can be looked at, the cursor moved and
/// everything used that is marked `runsDuringJobs`. `isBusy` stays true, so commands that
/// change files or panels remain blocked until the queue is empty: plugins start their work
/// from what the panels show and rely on that not changing under a running job, and the
/// service cannot know which of their commands would be safe.
internal final class ProgressJobService: JobService {
    /// One job of the queue.
    @MainActor
    private final class QueuedJob {
        /// The job's name, for the window and the questions about it.
        let title: String
        /// Asks the work to stop.
        let cancellation = CancellationFlag()
        /// Holds the work while the user pauses it.
        let gate = PauseGate()
        /// Starts the work.
        ///
        /// Set when the job is created, so the result type stays inside, and let go of when it
        /// has started, so that a kept handle keeps nothing of the work.
        var start: (() -> Void)?
        /// The job's progress, once it has started.
        var monitor: ProgressSheet?
        /// The user gave up waiting for it; the queue has moved on.
        var isAbandoned = false
        /// The work has returned.
        private(set) var isFinished = false

        /// A job called `title` that has not started.
        init(title: String) {
            self.title = title
        }

        /// Tells the work to stop.
        ///
        /// A job that has not started yet still runs, finds the request, and ends at once, so
        /// its completion is called like any other. A paused job is let go to find it.
        func cancel() {
            cancellation.cancel()
            gate.set(paused: false)
        }

        /// Notes that the work has returned.
        func finish() {
            isFinished = true
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The progress window.
    internal let display = ProgressDisplay()
    /// Called on the main thread when the first job is handed in and when the last one has ended.
    internal var onBusyChanged: (() -> Void)?
    /// How long a job that was told to stop may take before the user is asked about it.
    internal var patience: TimeInterval = 10
    /// Asks the user whether a job (by its title) that does not stop should be waited for no
    /// longer; true leaves it behind.
    ///
    /// Without it nobody is asked and the job is waited for.
    internal var askToAbandon: ((String) -> Bool)?
    /// Set while the program quits: the question above is the quitting's to ask.
    internal var isQuitting = false
    /// Whether the progress is shown in a window of its own instead of a sheet.
    ///
    /// Lasts until the queue is empty.
    internal private(set) var runsInBackground = false
    /// Jobs that were left behind and whose work has still not returned.
    internal private(set) var abandonedCount = 0
    /// The jobs waiting behind the running one.
    private var waiting: [QueuedJob] = []
    /// The running job.
    private var running: QueuedJob?
    /// Who waits for the queue to be empty (`cancelAll`).
    private var idleCallbacks: [() -> Void] = []
    /// Every job is being stopped (`cancelAll`): one that is handed in now is stopped as well.
    private var isCancellingAll = false
    /// Calls off the question about a job that does not stop.
    private var stopQuestion: (() -> Void)?

    /// The main window the sheet covers.
    internal weak var window: NSWindow? {
        didSet { display.window = window }
    }

    /// Whether a job runs or waits.
    internal var isBusy: Bool { running != nil || !waiting.isEmpty }

    /// The number of jobs waiting behind the running one.
    internal var queueLength: Int { waiting.count }

    /// Whether the running job is held.
    internal var isPaused: Bool { running?.gate.isPaused ?? false }

    /// A service without jobs.
    internal init() {
        display.service = self
    }

    /// Hands in a job: `work` runs on a thread of its own after the jobs before it, and
    /// `completion` gets its result on the main thread.
    internal func run<Result: Sendable>(
        title: String,
        work: @escaping @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        let job = QueuedJob(title: title)
        // What the plugin handed in may hold panels and windows: it is let go of on the main
        // thread, whichever thread is done with it last.
        let (ownedWork, ownedCompletion) = (MainOwned(work), MainOwned(completion))
        job.start = { [self, job] in
            let progress = ProgressSheet(title: title, cancellation: job.cancellation, gate: job.gate, display: display)
            job.monitor = progress
            display.begin(progress)
            Background.start(named: "afm.job", qos: .userInitiated) {
                // `held` is read here although the box is the main thread's: it was filled before
                // this thread existed and is emptied only after the work has returned.
                // The work is in its box until its result is back on the main thread.
                ownedWork.held.map { work in
                    let result = work(progress)
                    MainLoop.perform { [self] in
                        _ = ownedWork.take()
                        ended(job, progress) { ownedCompletion.take()?(result) }
                    }
                }
            }
        }
        // While everything is being stopped, nothing new runs to its end either.
        if isCancellingAll {
            job.cancel()
        }
        let wasBusy = isBusy
        waiting.append(job)
        if !wasBusy {
            onBusyChanged?()
        }
        if running == nil {
            startNext()
        } else {
            display.refresh()
        }
    }

    /// Stops every job, the running one and those waiting; `completion` is called once the
    /// queue is empty, at once when it is.
    internal func cancelAll(then completion: @escaping () -> Void) {
        guard isBusy else {
            completion()
            return
        }
        idleCallbacks.append(completion)
        isCancellingAll = true
        running?.cancel()
        for job in waiting {
            job.cancel()
        }
        display.refresh()
        if let running {
            watchStopping(running)
        }
    }

    /// Holds the running job at its next progress report, or lets it go on.
    ///
    /// A job that was asked to stop is not held.
    internal func setPaused(_ paused: Bool) {
        guard let running, paused != running.gate.isPaused, !(paused && running.cancellation.isCancelled) else {
            return
        }
        running.gate.set(paused: paused)
        // The pause must not count as slow copying.
        if !paused {
            running.monitor?.restartMeasuring()
        }
        display.refresh()
    }

    /// Stops the running job; the jobs behind it still run.
    internal func cancelCurrent() {
        running?.cancel()
        display.refresh()
        if let running {
            watchStopping(running)
        }
    }

    /// Turns the sheet into a window of its own, or back; only while a job runs.
    internal func setRunsInBackground(_ inBackground: Bool) {
        guard isBusy, inBackground != runsInBackground else {
            return
        }
        runsInBackground = inBackground
        display.modeChanged()
    }

    /// The work of `job` has returned; `deliver` calls its completion.
    ///
    /// Main thread.
    private func ended(_ job: QueuedJob, _ progress: ProgressSheet, deliver: () -> Void) {
        job.finish()
        guard !job.isAbandoned else {
            // Left behind long ago and back at last: the plugin hears of it (it tidies up and
            // reads the panels again), the queue has long moved on.
            abandonedCount -= 1
            deliver()
            return
        }
        guard running === job else {
            deliver()
            return
        }
        stopQuestion?()
        stopQuestion = nil
        // The window stays for the next job of the queue; the last one takes it away
        // before its completion may want to show something.
        display.end(progress, keepOpen: !waiting.isEmpty)
        running = nil
        if waiting.isEmpty {
            // The service is idle before the completion runs, and has said so: a completion
            // that shows a dialog must not leave commands free that still count as blocked,
            // nor the other way round.
            becomeIdle()
            deliver()
            runIdleCallbacks()
        } else {
            deliver()
            startNext()
        }
    }

    /// Starts the first waiting job.
    ///
    /// Called only while none runs and one waits.
    private func startNext() {
        let job = waiting.removeFirst()
        running = job
        let start = job.start
        job.start = nil
        start?()
        if job.cancellation.isCancelled {
            watchStopping(job)
        }
    }

    /// The queue is empty: the window goes, and whoever listens is told.
    private func becomeIdle() {
        runsInBackground = false
        display.close()
        onBusyChanged?()
    }

    /// Tells whoever waits for the queue to be empty (`cancelAll`), unless a completion has
    /// handed in the next job meanwhile.
    private func runIdleCallbacks() {
        guard !isBusy else {
            return
        }
        isCancellingAll = false
        let callbacks = idleCallbacks
        idleCallbacks = []
        for callback in callbacks {
            callback()
        }
    }

    /// `job` was told to stop; if it is still running after `patience`, the user is asked about it.
    ///
    /// Whether to wait on, and again after twice as long each time the answer is yes.
    private func watchStopping(_ job: QueuedJob) {
        guard stopQuestion == nil else {
            return
        }
        askAboutStopping(job, after: patience)
    }

    /// Asks about `job` after `wait`, if it is still running then.
    private func askAboutStopping(_ job: QueuedJob, after wait: TimeInterval) {
        // The job's thread holds the service while the job runs, and the wait is called off
        // whenever the job stops being the running one: it fires only for the running job.
        stopQuestion = MainLoop.after(wait) { [self] in
            stopQuestion = nil
            let abandons = !isQuitting && askToAbandon?(job.title) == true
            // The job may have ended while the question was on screen.
            guard running === job, !job.isFinished else {
                return
            }
            if abandons {
                abandon(job)
            } else {
                askAboutStopping(job, after: wait * 2)
            }
        }
    }

    /// Leaves the running job behind: its thread stays wherever it waits, the queue moves on.
    private func abandon(_ job: QueuedJob) {
        job.isAbandoned = true
        abandonedCount += 1
        if let monitor = job.monitor {
            display.end(monitor, keepOpen: !waiting.isEmpty)
        }
        running = nil
        if waiting.isEmpty {
            becomeIdle()
            runIdleCallbacks()
        } else {
            startNext()
        }
    }

    deinit {
        // Nothing to release.
    }
}
