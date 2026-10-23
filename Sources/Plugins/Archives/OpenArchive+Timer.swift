import Foundation

/// The timer that writes the changes a while after the last one.
extension OpenArchive {
    /// Notes a change and sees to it that it is written.
    ///
    /// Called with the lock held.
    internal func changed() {
        changeCount += 1
        lastChange = .now()
        if let delay = environment.flushDelay { armTimer(after: idleDelay(delay)) }
    }

    /// One timer at a time, however many changes arrive; one that is due earlier takes the
    /// place of the one that is armed (a change after a failed write does not wait for the
    /// retry).
    ///
    /// The timer holds on to the archive: an archive with changes waiting is not released before
    /// they are written, whoever else lets go of it. (Once the plugin has stopped, a timer that
    /// still fires does nothing.).
    ///
    /// The timer runs with low priority, which under full load may not run for minutes; a
    /// second one with the user's priority follows `escalationDelay` later and does the work
    /// if the first has not. Called with the lock held.
    internal func armTimer(after delay: TimeInterval) {
        let deadline = DispatchTime.now() + delay
        if let armed = timerDeadline, armed <= deadline {
            return
        }
        timerDeadline = deadline
        timerNumber += 1
        let number = timerNumber
        environment.schedule(delay, .utility) { self.timerFired(number) }
        environment.schedule(delay + environment.escalationDelay, .userInitiated) { self.timerFired(number) }
    }

    /// How long nothing must have changed before the timer writes.
    ///
    /// A write that copies the whole archive waits for a pause many times its own length, so that a
    /// slow job (a server, a question left unanswered) is not interleaved with rewrites of the
    /// archive.
    internal func idleDelay(_ base: TimeInterval) -> TimeInterval {
        writesWholeArchive ? max(base, min(60, 20 * lastRewriteDuration)) : base
    }

    /// A timer is due: writes what waits, once the changes have paused.
    private func timerFired(_ number: Int) {
        guard let wait = dueWrite(number) else {
            return
        }
        do {
            try flush(leavingOutArrivals: false, cancellation: environment.quitting) { _, _ in true }
        } catch {
            let isNews = noteFailedWrite(error, wait: wait)
            if case ArchiveError.cancelled = error {
                return
            }
            if isNews { environment.reportFailure(error, name) }
        }
        environment.contentsChanged(archiveURL)
    }

    /// What the timer with this number finds when it fires: the pause the write waited for, or
    /// nil when it is not to write now.
    ///
    /// Nil when a later timer overtook it, its twin wrote already, the program quits, nothing
    /// waits (then the panels hear of the last write, if they are to), a member is being
    /// written, or the changes have not paused long enough (then the next timer is armed).
    private func dueWrite(_ number: Int) -> TimeInterval? {
        lock.lock()
        // Overtaken by a later timer, or done already by its twin.
        guard number == timerNumber, timerDeadline != nil else {
            lock.unlock()
            return nil
        }
        timerDeadline = nil
        // The program is quitting: the stop writes what waits.
        guard !environment.isStopping else {
            lock.unlock()
            return nil
        }
        let notify = notifyPending && !hasPendingLocked
        if notify { notifyPending = false }
        // Nothing waits: the next rename may write again.
        if !hasPendingLocked { (immediateSpent, arrivedBytes) = (0, 0) }
        guard hasPendingLocked, let base = environment.flushDelay else {
            lock.unlock()
            if notify { environment.contentsChanged(archiveURL) }
            return nil
        }
        // Not while a member is being written (the end of the writer arms the timer again),
        // and not before the changes have paused.
        guard openWriters == 0 else {
            lock.unlock()
            return nil
        }
        let wait = idleDelay(base)
        let idle = Double(DispatchTime.now().uptimeNanoseconds &- lastChange.uptimeNanoseconds) / 1_000_000_000
        if idle < wait {
            armTimer(after: max(0.01, wait - idle))
            lock.unlock()
            return nil
        }
        notifyPending = false
        lock.unlock()
        return wait
    }

    /// Notes a write of the timer that failed; true when the user is to hear of it.
    ///
    /// The changes are still waiting. The user hears of a failure once; the write is tried
    /// again later, each time after twice as long, and at once when something changes.
    private func noteFailedWrite(_ error: any Error, wait: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let text = error.localizedDescription
        let isNews = reportedFailure != text
        reportedFailure = text
        failures += 1
        if hasPendingLocked, !environment.isStopping {
            let pause = max(environment.retryDelay, wait) * pow(2, Double(min(failures - 1, 20)))
            armTimer(after: min(pause, max(environment.maxRetryDelay, environment.retryDelay)))
        }
        return isNews
    }

    /// Whether the archive's file system makes clones, as far as is known (`probeCloning`
    /// tried it before the first change; a write that could not clone corrects it); unknown
    /// when the try said neither.
    ///
    /// Called with the lock held; asks nothing.
    internal func clones() -> Cloning {
        environment.clonesArchives ? canClone : .unsupported
    }
}
