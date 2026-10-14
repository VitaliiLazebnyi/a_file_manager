import Foundation

/// Pieces: how the callers and the pool's threads take the indexes of the jobs and work on them.
extension ParallelPool {
    /// Takes the next piece of a job; nil when every piece is taken.
    ///
    /// Called with the lock held.
    internal func take(from job: Job) -> Range<Int>? {
        guard job.next < job.count else {
            return nil
        }
        let piece = job.next..<min(job.next + job.grain, job.count)
        job.next = piece.upperBound
        job.inFlight += 1
        if job.next == job.count, let index = open.firstIndex(where: { $0 === job }) { open.remove(at: index) }
        return piece
    }

    /// Runs a piece on this thread.
    ///
    /// Called without the lock. `tree` is the tree a thread of the pool was counted for when it took the piece; nil for
    /// the caller of `run`.
    internal func perform(_ piece: Range<Int>, of job: Job, countedFor tree: Job?) {
        let outer = current
        current = job
        // The closure is only borrowed for the piece: it is let go before the piece counts as
        // done. What the work leaves to be released later is released with the piece, and not
        // when the thread ends, which may be never. (It is there for as long as pieces are.)
        if let body = job.body {
            if job.grain > 16 {
                autoreleasepool { for index in piece { body(index) } }
            } else {
                for index in piece { autoreleasepool { body(index) } }
            }
        }
        current = outer
        condition.lock()
        job.inFlight -= 1
        job.root.finished &+= 1
        tree?.threads -= 1
        if job.inFlight == 0, job.next == job.count { job.sleeper?.signal() }
        condition.unlock()
    }

    /// The caller's share of its own job: pieces until none is left to take.
    internal func work(on job: Job) {
        while true {
            condition.lock()
            let piece = take(from: job)
            condition.unlock()
            guard let piece else {
                return
            }
            perform(piece, of: job, countedFor: nil)
        }
    }

    /// Starts a thread of the pool's own, counted in `threads` already.
    internal func startThread() {
        let thread = Thread { [self] in serve() }
        thread.name = "AFM.Parallel"
        thread.qualityOfService = .userInitiated
        // Room for work that goes deep (a walk calls itself for every level of folders).
        thread.stackSize = 2 << 20
        thread.start()
    }

    /// The job a free thread of the pool takes a piece of: of the trees that may have another thread, the one the main
    /// thread waits for, else the one with the fewest threads; within a tree the oldest job.
    ///
    /// Called with the lock held.
    private func jobForFreeThread() -> Job? {
        var best: Job?
        var bestRank = Int.max
        for job in open {
            let root = job.root
            guard root.threads < width + root.allowance else { continue }
            let rank = root.isForMain ? root.threads - limit : root.threads
            if rank < bestRank {
                (best, bestRank) = (job, rank)
            }
        }
        return best
    }

    /// What a thread of the pool does for as long as it lives: pieces of whatever tree needs it
    /// most, then a wait to be called, and it leaves when it waited in vain or is retired.
    private func serve() {
        let own = pthread_mach_thread_np(pthread_self())
        var urgency = QOS_CLASS_USER_INITIATED
        var timedOut = false
        condition.lock()
        workers[own] = (Self.processorTime(of: own)?.used ?? 0, nil)
        while true {
            if retiring > 0 {
                retiring -= 1
                break
            }
            if let job = jobForFreeThread(), let piece = take(from: job) {
                let tree = job.root
                tree.threads += 1
                workers[own]?.tree = tree
                condition.unlock()
                timedOut = false
                // The piece is as urgent as whoever waits for it.
                if tree.urgency != urgency {
                    urgency = tree.urgency
                    pthread_set_qos_class_self_np(urgency, 0)
                }
                perform(piece, of: job, countedFor: tree)
                condition.lock()
                workers[own]?.tree = nil
                continue
            }
            // Nothing to do: wait a while to be called, then leave.
            if timedOut { break }
            idle += 1
            let end = Date(timeIntervalSinceNow: linger)
            while summons == 0, retiring == 0, !timedOut { timedOut = !condition.wait(until: end) }
            idle -= 1
            // Called: there is work, or was a moment ago. (A call that comes with the
            // last tick of the wait counts as well; the work is looked for once more.)
            if summons > 0 {
                summons -= 1
                timedOut = false
            }
        }
        workers[own] = nil
        threads -= 1
        condition.unlock()
    }
}
