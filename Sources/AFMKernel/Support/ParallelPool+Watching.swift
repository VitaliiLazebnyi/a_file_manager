import Foundation

/// Watching: one thread of the pool's own looks at the others while there is work, and starts
/// or retires threads.
extension ParallelPool {
    /// The processor time a thread has used so far, in nanoseconds, and whether it is ready to
    /// run (as opposed to blocked).
    ///
    /// When the system does not say (the thread has just ended), the answer is no time and not
    /// ready: such a thread seems to have gone back in time and does not count as waiting.
    internal static func processorTime(of thread: thread_t) -> (used: UInt64, isRunnable: Bool) {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        // On failure `info` is left as it was made: all zero.
        _ = withUnsafeMutablePointer(to: &info) { info in
            info.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), words, &count)
            }
        }
        let seconds = UInt64(info.user_time.seconds) + UInt64(info.system_time.seconds)
        let microseconds = UInt64(info.user_time.microseconds) + UInt64(info.system_time.microseconds)
        return (seconds * 1_000_000_000 + microseconds * 1_000, info.run_state == TH_STATE_RUNNING)
    }

    /// Has the threads looked at soon, and again for as long as there is work or a thread too many.
    ///
    /// Called with the lock held.
    internal func watch() {
        let wasPatient = interval > Self.patience
        interval = Self.patience
        if !isWatching {
            isWatching = true
            if !hasWatcher {
                hasWatcher = true
                let thread = Thread { [self] in watcher() }
                thread.name = "AFM.Parallel.watch"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
            watcherWake.signal()
        } else if wasPatient {
            // It sleeps long; new work wants a look soon.
            watcherWake.signal()
        }
    }

    /// Calls up to `wanted` idle threads to work and returns how many were called.
    ///
    /// Called with the lock held.
    internal func summon(_ wanted: Int) -> Int {
        let called = min(max(0, idle - summons), wanted)
        guard called > 0 else {
            return 0
        }
        summons += called
        if called == 1 { condition.signal() } else { condition.broadcast() }
        return called
    }

    /// The watching thread: a thread of the pool's own and not a timer on a dispatch queue,
    /// because those queues can all be taken by work that waits, and the pool has to grow
    /// just then.
    private func watcher() {
        while true {
            condition.lock()
            let (isWanted, pause) = (isWatching, interval)
            condition.unlock()
            guard isWanted else {
                watcherWake.wait()
                continue
            }
            // Woken before the time: the pause has changed, and so it starts again. (A look
            // right now would have nothing to measure the threads by.)
            if watcherWake.wait(timeout: .now() + .nanoseconds(Int(pause))) == .success { continue }
            for _ in 0..<look() { startThread() }
        }
    }

    /// Looks at the threads: one that is at a piece but has hardly used the processor since the last look is waiting
    /// for something and leaves its core free.
    ///
    /// Work that nobody takes then gets idle or new threads, as far as its tree may have them, and threads beyond the
    /// cores that are ready to run are told to go. Returns the number of threads to start, which are counted already.
    private func look() -> Int {
        condition.lock()
        defer { condition.unlock() }
        let (waiting, waitingIn) = countWaiting()
        blocked = waiting
        let (demand, grew) = demandOfOpenJobs(waitingIn: waitingIn)
        let woken = summon(demand)
        let ready = threads - min(waiting, threads)
        let starts = max(0, min(demand - woken, width - ready, limit - threads))
        threads += starts
        // More threads ready to run than cores, the idle ones among them: the stall that
        // made them is over.
        retiring = starts > 0 ? 0 : max(0, ready - width - woken)
        if retiring > 0, idle > 0 { condition.broadcast() }
        let changed = grew || starts > 0 || woken > 0 || retiring > 0
        interval = changed ? Self.patience : min(interval * 2, Self.longestPatience)
        if open.isEmpty, threads <= width { isWatching = false }
        return starts
    }

    /// The pool's threads that are at a piece and have hardly used the processor since the last look.
    ///
    /// Counted in all and by tree; the time each has used is noted. Called with the lock held.
    private func countWaiting() -> (all: Int, byTree: [ObjectIdentifier: Int]) {
        var waiting = 0
        var waitingIn: [ObjectIdentifier: Int] = [:]
        for (thread, state) in workers {
            let (time, isRunnable) = Self.processorTime(of: thread)
            // A thread that the machine has no core for is not waiting for anything.
            if let tree = state.tree, !isRunnable, time &- state.used < Self.patience / 4 {
                waiting += 1
                waitingIn[ObjectIdentifier(tree), default: 0] += 1
            }
            workers[thread]?.used = time
        }
        return (waiting, waitingIn)
    }

    /// The pieces of the open jobs that threads could be put to, and whether a tree was given more.
    ///
    /// Each tree counts as far as it may have threads. Called with the lock held.
    private func demandOfOpenJobs(waitingIn: [ObjectIdentifier: Int]) -> (demand: Int, grew: Bool) {
        var grew = false
        var demand = 0
        var seen = Set<ObjectIdentifier>()
        for job in open {
            let root = job.root
            if seen.insert(ObjectIdentifier(root)).inserted {
                grew = grow(root, stuck: waitingIn[ObjectIdentifier(root)] ?? 0) || grew
                root.room = max(0, width + root.allowance - root.threads)
            }
            let given = min(job.piecesLeft, root.room)
            root.room -= given
            demand += given
        }
        return (demand, grew)
    }

    /// Gives a tree more threads than cores when its threads wait and its pieces get done all the same.
    ///
    /// Such a tree waits for answers that come, and more threads make it faster. One whose
    /// pieces do not get done keeps what it has. True when it was given more. Called with the
    /// lock held.
    private func grow(_ root: Job, stuck: Int) -> Bool {
        guard root.finished != root.seenFinished else {
            return false
        }
        root.seenFinished = root.finished
        guard stuck > 0, root.threads >= width + root.allowance, root.allowance < treeLimit - width else {
            return false
        }
        root.allowance = min(treeLimit - width, root.allowance + stuck)
        return true
    }
}
