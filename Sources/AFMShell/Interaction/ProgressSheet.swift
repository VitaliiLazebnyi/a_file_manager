import AFMContracts
import AFMKernel
import Foundation

/// The progress of one job and the job's way to ask the user something.
///
/// What the work reports on its own thread is brought to the main thread here, where the
/// progress window reads it.
///
/// Unchecked: the main thread's part is isolated to it, the report counters are guarded by
/// `reportLock`, and the rest does not change (`display` is weak, and so a `var`).
internal final class ProgressSheet: JobMonitor, @unchecked Sendable {
    /// Where a job's question waits for the main thread, and its answer for the job.
    ///
    /// Unchecked: the job's thread fills it and then waits until the main thread has answered.
    private final class AskSlot<Answer>: @unchecked Sendable {
        /// The question, until the main thread takes it.
        var question: (@MainActor () -> Answer)?
        /// The answer, once the main thread has given it.
        var answer: Answer?

        deinit {
            // Nothing to release.
        }
    }

    /// Tells the work to stop.
    internal let cancellation: CancellationFlag
    /// The job's name.
    internal let title: String
    /// The job's last report as the window shows it; main thread.
    @MainActor internal private(set) var latest: JobProgress?
    /// How fast the job advances; main thread.
    @MainActor internal private(set) var rate = TransferRate()
    /// Holds the work while the user pauses it.
    private let gate: PauseGate
    /// The window that shows the progress.
    private weak var display: ProgressDisplay?
    /// The number of the report `latest` is; main thread.
    @MainActor private var shownReport = 0
    /// Guards `lastReport` and `reportCount`: a job may report from several threads at once.
    private let reportLock = NSLock()
    /// When the last report was passed on, in the system's uptime.
    private var lastReport: TimeInterval = 0
    /// How many reports were passed on.
    private var reportCount = 0

    /// The progress of the job `title`, held by `gate` and shown by `display`.
    internal init(title: String, cancellation: CancellationFlag, gate: PauseGate, display: ProgressDisplay?) {
        self.title = title
        self.cancellation = cancellation
        self.gate = gate
        self.display = display
    }

    /// The speed line: `11.06 M/s  ·  about 1 min 20 s left`.
    ///
    /// A job that moves no data shows only the time.
    internal static func speedLine(_ rate: TransferRate, for progress: JobProgress) -> String {
        guard let perSecond = rate.perSecond else {
            return "Calculating…"
        }
        var parts: [String] = []
        if progress.measuresBytes {
            parts.append(Format.speed(perSecond))
        }
        if let remaining = rate.remaining(total: progress.amountTotal) {
            parts.append("about \(Format.duration(remaining)) left")
        }
        return parts.isEmpty ? " " : parts.joined(separator: "  ·  ")
    }

    /// Items done / items, and the amount of data once the job knows it.
    ///
    /// With `remaining`, what is still to do, with a minus sign (spec 07 › Progress window:
    /// clicking a count).
    internal static func countLine(for progress: JobProgress, remaining: Bool) -> String {
        let items = remaining ? "-\(max(0, progress.itemsTotal - progress.itemsDone))" : "\(progress.itemsDone)"
        var count = "\(items) / \(progress.itemsTotal)"
        if progress.measuresBytes {
            let bytes =
                remaining
                ? "-" + Format.shortSize(max(0, progress.bytesTotal - progress.bytesDone))
                : Format.shortSize(progress.bytesDone)
            count += "     \(bytes) of \(Format.shortSize(progress.bytesTotal))"
        }
        return count
    }

    /// The jobs behind the running one: nothing, `1 more job waiting`, `3 more jobs waiting`.
    internal static func queueLine(_ waiting: Int) -> String {
        if waiting <= 0 {
            return ""
        }
        return waiting == 1 ? "1 more job waiting" : "\(waiting) more jobs waiting"
    }

    /// Forgets the measured speed, after the job stood still for a reason of the user's.
    @MainActor
    internal func restartMeasuring() {
        rate.reset()
    }

    /// Passes a report on to the progress window, at most twenty a second; on the job's thread.
    ///
    /// A paused job waits in here (see the service for what that asks of the caller). Reports
    /// from several threads may overtake each other on their way to the main thread: each gets
    /// a number, and one that arrives after a newer one is dropped, so the window never steps
    /// back.
    internal func report(_ progress: JobProgress) {
        gate.passWhenOpen(cancellation)
        let time = ProcessInfo.processInfo.systemUptime
        let number: Int? = reportLock.withLock {
            guard time - lastReport > 0.05 else {
                return nil
            }
            lastReport = time
            reportCount += 1
            return reportCount
        }
        guard let number else {
            return
        }
        DispatchQueue.main.async { [self] in
            guard number > shownReport else {
                return
            }
            shownReport = number
            latest = progress
            rate.add(amount: progress.amountDone, at: time)
            display?.render(self)
        }
    }

    /// Asks on the main thread and waits for the answer; on the job's thread.
    ///
    /// The question is put from the run loop, not from inside a block of the main dispatch
    /// queue, where its dialog would keep everything else that was sent to the main thread
    /// waiting (`MainLoop`). Whoever asks from the main thread is answered there.
    internal func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
        // A job has no business on the main thread; whoever asks from there is answered there.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { put(question) }
        }
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
                slot.answer = asked.map { self.put($0) }
                asked = nil
                answered.signal()
            }
            answered.wait()
        }
        // The wait above ends only after the main thread has put the question and set the answer.
        return slot.answer.unsafelyUnwrapped
    }

    /// Shows the progress and asks; main thread.
    @MainActor
    private func put<Answer>(_ question: @MainActor () -> Answer) -> Answer {
        display?.show()
        let answer = question()
        // The wait for the answer must not count as slow copying.
        rate.reset()
        return answer
    }

    deinit {
        // Nothing to release.
    }
}
