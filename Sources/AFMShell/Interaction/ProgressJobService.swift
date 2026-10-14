import AFMContracts
import AFMKernel
import AppKit

/// Runs the plugins' long work in the background, one job after another in the order they
/// were handed in, with a progress window (spec 07 › Progress window and job sequence). The
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
final class ProgressJobService: JobService {
    weak var window: NSWindow? {
        didSet { display.window = window }
    }
    private var waiting: [QueuedJob] = []
    private var running: QueuedJob?
    private var idleCallbacks: [() -> Void] = []
    /// Called on the main thread when the first job is handed in and when the last one has ended.
    var onBusyChanged: (() -> Void)?
    let display = ProgressDisplay()
    /// Whether the progress is shown in a window of its own instead of a sheet. Lasts until
    /// the queue is empty.
    private(set) var runsInBackground = false
    /// How long a job that was told to stop may take before the user is asked about it.
    var patience: TimeInterval = 10
    /// Asks the user whether a job (by its title) that does not stop should be waited for no
    /// longer; true leaves it behind. Without it nobody is asked and the job is waited for.
    var askToAbandon: ((String) -> Bool)?
    /// Set while the program quits: the question above is the quitting's to ask.
    var isQuitting = false
    /// Jobs that were left behind and whose work has still not returned.
    private(set) var abandonedCount = 0
    /// Every job is being stopped (`cancelAll`): one that is handed in now is stopped as well.
    private var isCancellingAll = false
    private var stopQuestion: (() -> Void)?

    init() {
        display.service = self
    }

    var isBusy: Bool { running != nil || !waiting.isEmpty }

    /// The number of jobs waiting behind the running one.
    var queueLength: Int { waiting.count }

    /// The progress of the running job; nil while none runs.
    var current: ProgressSheet? { running?.monitor }

    private final class QueuedJob: JobHandle {
        let title: String
        let cancellation = CancellationFlag()
        let gate = PauseGate()
        private(set) var isFinished = false
        /// Starts the work; set when the job is created, so the result type stays inside, and
        /// let go of when it has started, so that a kept handle keeps nothing of the work.
        var start: (() -> Void)?
        var monitor: ProgressSheet?
        /// The user gave up waiting for it; the queue has moved on.
        var isAbandoned = false

        init(title: String) { self.title = title }

        /// A job that has not started yet still runs, finds the request, and ends at once, so
        /// its completion is called like any other. A paused job is let go to find it.
        func cancel() {
            cancellation.cancel()
            gate.set(paused: false)
        }

        func finish() { isFinished = true }
    }

    @discardableResult
    func run<Result>(title: String, work: @escaping (JobMonitor) -> Result, completion: @escaping (Result) -> Void) -> JobHandle {
        MainThread.assert("The job service")
        let job = QueuedJob(title: title)
        // What the plugin handed in may hold panels and windows: it is let go of on the main
        // thread, whichever thread is done with it last.
        let (work, completion) = (MainOwned(work), MainOwned(completion))
        job.start = { [self, job] in
            let progress = ProgressSheet(title: title, cancellation: job.cancellation, gate: job.gate, display: display)
            job.monitor = progress
            display.begin(progress)
            Background.start(named: "afm.job", qos: .userInitiated) {
                // `held` is read here although the box is the main thread's: it was filled before
                // this thread existed and is emptied only after the work has returned.
                guard let result = work.held.map({ $0(progress) }) else { return }
                MainLoop.perform { [self] in
                    _ = work.take()
                    ended(job, progress) { completion.take()?(result) }
                }
            }
        }
        // While everything is being stopped, nothing new runs to its end either.
        if isCancellingAll { job.cancel() }
        let wasBusy = isBusy
        waiting.append(job)
        if !wasBusy { onBusyChanged?() }
        if running == nil { startNext() } else { display.refresh() }
        return job
    }

    /// Main thread: the work of `job` has returned; `deliver` calls its completion.
    private func ended(_ job: QueuedJob, _ progress: ProgressSheet, deliver: () -> Void) {
        job.finish()
        guard !job.isAbandoned else {
            // Left behind long ago and back at last: the plugin hears of it (it tidies up and
            // reads the panels again), the queue has long moved on.
            abandonedCount -= 1
            return deliver()
        }
        guard running === job else { return deliver() }
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

    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        running = job
        let start = job.start
        job.start = nil
        start?()
        if job.cancellation.isCancelled { watchStopping(job) }
    }

    private func becomeIdle() {
        runsInBackground = false
        display.close()
        onBusyChanged?()
    }

    /// Tells whoever waits for the queue to be empty (`cancelAll`), unless a completion has
    /// handed in the next job meanwhile.
    private func runIdleCallbacks() {
        guard !isBusy else { return }
        isCancellingAll = false
        let callbacks = idleCallbacks
        idleCallbacks = []
        callbacks.forEach { $0() }
    }

    func cancelAll(then completion: @escaping () -> Void) {
        MainThread.assert("The job service")
        guard isBusy else { return completion() }
        idleCallbacks.append(completion)
        isCancellingAll = true
        running?.cancel()
        waiting.forEach { $0.cancel() }
        display.refresh()
        if let running { watchStopping(running) }
    }

    // MARK: A job that does not stop

    /// `job` was told to stop. If it is still running after `patience`, the user is asked
    /// whether to wait on, and again after twice as long each time the answer is yes.
    private func watchStopping(_ job: QueuedJob) {
        guard stopQuestion == nil else { return }
        askAboutStopping(job, after: patience)
    }

    private func askAboutStopping(_ job: QueuedJob, after wait: TimeInterval) {
        stopQuestion = MainLoop.after(wait) { [weak self, weak job] in
            guard let self else { return }
            self.stopQuestion = nil
            guard let job, self.running === job, !job.isFinished else { return }
            let abandons = !self.isQuitting && self.askToAbandon?(job.title) == true
            // The job may have ended while the question was on screen.
            guard self.running === job, !job.isFinished else { return }
            if abandons { self.abandon(job) } else { self.askAboutStopping(job, after: wait * 2) }
        }
    }

    /// Leaves the running job behind: its thread stays wherever it waits, the queue moves on.
    private func abandon(_ job: QueuedJob) {
        job.isAbandoned = true
        abandonedCount += 1
        if let monitor = job.monitor { display.end(monitor, keepOpen: !waiting.isEmpty) }
        running = nil
        if waiting.isEmpty {
            becomeIdle()
            runIdleCallbacks()
        } else {
            startNext()
        }
    }

    /// Leaves the running job behind without asking, if it was told to stop and has not:
    /// for quitting, once the user has said not to wait. Jobs behind it were told to stop
    /// as well and are given their turn.
    func abandonStoppingJob() {
        MainThread.assert("The job service")
        guard let running, running.cancellation.isCancelled, !running.isFinished else { return }
        stopQuestion?()
        stopQuestion = nil
        abandon(running)
    }

    // MARK: What the progress window offers

    var isPaused: Bool { running?.gate.isPaused ?? false }

    /// Holds the running job at its next progress report, or lets it go on. A job that was
    /// asked to stop is not held.
    func setPaused(_ paused: Bool) {
        MainThread.assert("The job service")
        guard let running, paused != running.gate.isPaused, !(paused && running.cancellation.isCancelled) else { return }
        running.gate.set(paused: paused)
        // The pause must not count as slow copying.
        if !paused { running.monitor?.restartMeasuring() }
        display.refresh()
    }

    /// Stops the running job; the jobs behind it still run.
    func cancelCurrent() {
        MainThread.assert("The job service")
        running?.cancel()
        display.refresh()
        if let running { watchStopping(running) }
    }

    /// Turns the sheet into a window of its own, or back.
    func setRunsInBackground(_ inBackground: Bool) {
        MainThread.assert("The job service")
        guard isBusy, inBackground != runsInBackground else { return }
        runsInBackground = inBackground
        display.modeChanged()
    }
}

/// Where a paused job waits. Safe to use from any thread.
final class PauseGate {
    private let condition = NSCondition()
    private var paused = false

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    func set(paused: Bool) {
        condition.lock()
        self.paused = paused
        condition.broadcast()
        condition.unlock()
    }

    /// Called on the job's thread: returns at once unless the job is paused, and then when it
    /// is resumed or cancelled. The cancellation is also looked at every now and then, because
    /// the flag can be set by anyone without telling the gate.
    func passWhenOpen(_ cancellation: CancellationFlag) {
        condition.lock()
        while paused && !cancellation.isCancelled {
            condition.wait(until: Date().addingTimeInterval(0.1))
        }
        condition.unlock()
    }
}

/// Where a job's question waits for the main thread, and its answer for the job.
private final class AskSlot<Answer> {
    var question: (() -> Answer)?
    var answer: Answer?
}

/// The progress of one job and the job's way to ask the user something: what the work reports
/// on its own thread is brought to the main thread here, where the progress window reads it.
final class ProgressSheet: JobMonitor {
    let cancellation: CancellationFlag
    let title: String
    private let gate: PauseGate
    private weak var display: ProgressDisplay?

    // Main thread only.
    private(set) var latest: JobProgress?
    private(set) var rate = TransferRate()
    /// The number of the report `latest` is.
    private var shownReport = 0
    /// When the last report was passed on and which number it got; behind the lock, because
    /// a job may report from several threads at once.
    private let reportLock = NSLock()
    private var lastReport: TimeInterval = 0
    private var reportCount = 0

    init(title: String, cancellation: CancellationFlag, gate: PauseGate = PauseGate(), display: ProgressDisplay? = nil) {
        self.title = title
        self.cancellation = cancellation
        self.gate = gate
        self.display = display
    }

    /// Forgets the measured speed, after the job stood still for a reason of the user's.
    func restartMeasuring() {
        rate.reset()
    }

    // MARK: JobMonitor (called on the job's thread)

    /// Passes a report on to the progress window, at most twenty a second. A paused job waits
    /// in here (see the service for what that asks of the caller). Reports from several
    /// threads may overtake each other on their way to the main thread: each gets a number,
    /// and one that arrives after a newer one is dropped, so the window never steps back.
    func report(_ progress: JobProgress) {
        gate.passWhenOpen(cancellation)
        let time = ProcessInfo.processInfo.systemUptime
        reportLock.lock()
        guard time - lastReport > 0.05 else { return reportLock.unlock() }
        lastReport = time
        reportCount += 1
        let number = reportCount
        reportLock.unlock()
        DispatchQueue.main.async { [self] in
            guard number > shownReport else { return }
            shownReport = number
            latest = progress
            rate.add(amount: progress.amountDone, at: time)
            display?.render(self)
        }
    }

    /// Asks on the main thread and waits for the answer. The question is put from the run
    /// loop, not from inside a block of the main dispatch queue, where its dialog would keep
    /// everything else that was sent to the main thread waiting (`MainLoop`).
    func ask<Answer>(_ question: () -> Answer) -> Answer {
        func put(_ question: () -> Answer) -> Answer {
            display?.show()
            let answer = question()
            // The wait for the answer must not count as slow copying.
            rate.reset()
            return answer
        }
        // A job has no business on the main thread; whoever asks from there is answered there.
        if Thread.isMainThread { return put(question) }
        let slot = AskSlot<Answer>()
        let answered = DispatchSemaphore(value: 0)
        withoutActuallyEscaping(question) { question in
            slot.question = question
            MainLoop.perform {
                // The question is let go of here, before the job's thread is woken: the run
                // loop keeps this block a moment longer than it runs it, and the question
                // must not be held by anybody when the job's thread goes on.
                var asked = slot.question
                slot.question = nil
                slot.answer = asked.map { put($0) }
                asked = nil
                answered.signal()
            }
            answered.wait()
        }
        return slot.answer!
    }

    // MARK: Texts

    /// `11.06 M/s  ·  about 1 min 20 s left`; a job that moves no data shows only the time.
    static func speedLine(_ rate: TransferRate, for progress: JobProgress) -> String {
        guard let perSecond = rate.perSecond else { return "Calculating…" }
        var parts: [String] = []
        if progress.measuresBytes { parts.append(Format.speed(perSecond)) }
        if let remaining = rate.remaining(total: progress.amountTotal) {
            parts.append("about \(Format.duration(remaining)) left")
        }
        return parts.isEmpty ? " " : parts.joined(separator: "  ·  ")
    }

    /// Items done / items, and the amount of data once the job knows it. With `remaining`,
    /// what is still to do, with a minus sign (spec 07 › Progress window: clicking a count).
    static func countLine(for progress: JobProgress, remaining: Bool = false) -> String {
        let items = remaining ? "-\(max(0, progress.itemsTotal - progress.itemsDone))" : "\(progress.itemsDone)"
        var count = "\(items) / \(progress.itemsTotal)"
        if progress.measuresBytes {
            let bytes = remaining ? "-" + Format.shortSize(max(0, progress.bytesTotal - progress.bytesDone)) : Format.shortSize(progress.bytesDone)
            count += "     \(bytes) of \(Format.shortSize(progress.bytesTotal))"
        }
        return count
    }

    /// The jobs behind the running one: nothing, `1 more job waiting`, `3 more jobs waiting`.
    static func queueLine(_ waiting: Int) -> String {
        waiting <= 0 ? "" : waiting == 1 ? "1 more job waiting" : "\(waiting) more jobs waiting"
    }
}
