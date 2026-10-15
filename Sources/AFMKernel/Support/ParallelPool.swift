import Foundation

/// The threads behind `Parallel.map`.
///
/// Every call opens a job: a range of indexes that the caller and the pool's threads take pieces of until none is left.
/// A thread that runs out of pieces while others still work on its job does not sleep if it can help it: it takes
/// pieces of the jobs that were opened below its own (the nested calls), which is work its own job is waiting for
/// anyway. It never takes unrelated work, so a call returns as soon as its own work is done, and it never waits for a
/// thread that has not started, so nesting cannot deadlock.
///
/// A job that was not opened from inside another, with everything opened below it, is a tree.
/// The pool's threads are shared out between the trees: a thread that is free takes a piece
/// of the tree that has the fewest threads (first of all one the main thread waits for), and
/// no tree gets more than as many threads as there are cores. So when the pieces of one tree
/// stop (a walk over a volume that no longer answers), that tree keeps the threads it has and
/// no more, and every other call still finds its helpers.
///
/// There are as many helper threads as cores, less one for the caller. Pieces that wait
/// (for a server, a disk, another program) keep their threads without using a core. A thread
/// of the pool's own therefore looks at what the others are doing while there is work: for
/// those that are waiting rather than computing it starts others, up to a fixed limit, and a
/// tree whose pieces wait and yet get done (they wait for answers that come) is given more
/// threads than cores. Threads beyond the cores go away as soon as they are not needed, and
/// all of them when there is nothing left to do. The pool uses no dispatch queue: it keeps
/// working when those are all taken.
///
/// All state, the counters of every `Job` included, is guarded by `condition`. The pool is
/// spread over files by subject (`ParallelPool+Job`, `+Watching`, `+Pieces`); what they share
/// is internal, and nothing outside the pool touches it.
internal final class ParallelPool: @unchecked Sendable {
    /// The pool of the program, whose idle threads stay for two seconds.
    internal static let shared = ParallelPool(linger: 2)
    /// How often the threads are looked at while there is work, in nanoseconds.
    internal static let patience: UInt64 = 20_000_000
    /// How seldom they are looked at when looking has stopped changing anything, in nanoseconds.
    internal static let longestPatience: UInt64 = 1_000_000_000
    /// The job whose piece runs on the current thread, kept with the thread.
    ///
    /// The job is not retained here: it outlives every one of its pieces.
    private static let currentJob: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    /// Helper threads besides the callers themselves.
    internal let width = max(0, ProcessInfo.processInfo.activeProcessorCount - 1)
    /// Guards everything below, and the counters of every job.
    internal let condition = NSCondition()
    /// Jobs with pieces left, oldest first: within a tree the oldest are the nearest to its
    /// top, and their pieces are the largest.
    internal var open: [Job] = []
    /// The pool's threads, idle ones included, and those counted already that are starting.
    internal var threads = 0
    /// The pool's threads that wait to be called to work.
    internal var idle = 0
    /// Idle threads that were called to work and have not come round yet.
    ///
    /// An idle thread waits for this number to be above zero, not for the signal that goes with it: a signal that finds
    /// nobody waiting is lost, a number is not.
    internal var summons = 0
    /// For how long a thread with nothing to do stays, in seconds.
    internal let linger: TimeInterval
    /// Threads that are to leave when they next look for work: more are ready to run than
    /// there are cores.
    internal var retiring = 0
    /// The pool's threads: the processor time each had used when last looked at, and the tree
    /// it is at a piece of.
    internal var workers: [thread_t: (used: UInt64, tree: Job?)] = [:]
    /// How many of the threads were waiting rather than computing at the last look.
    internal var blocked = 0
    /// The threads are looked at: there is work, or a thread too many.
    internal var isWatching = false
    /// The watching thread was started; it stays for as long as the pool.
    internal var hasWatcher = false
    /// The pause before the next look.
    internal var interval = ParallelPool.patience
    /// Wakes the watching thread: to start watching, or to look sooner than it meant to.
    internal let watcherWake = DispatchSemaphore(value: 0)

    /// The most threads one tree can have, counting those it is given because its pieces wait.
    internal var treeLimit: Int { width * 4 }
    /// The most threads there can ever be.
    internal var limit: Int { max(64, width * 16) }

    /// The job whose piece runs on the calling thread; nil outside the pool's work.
    internal var current: Job? {
        get { pthread_getspecific(Self.currentJob).map { Unmanaged<Job>.fromOpaque($0).takeUnretainedValue() } }
        set {
            pthread_setspecific(
                Self.currentJob,
                newValue.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
            )
        }
    }

    /// Whether the calling thread is at a piece of a tree the main thread waits for.
    internal var isWorkingForMainThread: Bool { current?.root.isForMain ?? false }

    /// A pool whose idle threads stay for `linger` seconds.
    ///
    /// The program has one, `shared`.
    internal init(linger: TimeInterval) {
        self.linger = linger
    }

    /// The urgency the pool's threads work with for a caller: the caller's own, but never so
    /// low that the system may leave the work lying for long.
    internal static func urgencyOfCaller() -> qos_class_t {
        let own = qos_class_self()
        if own == QOS_CLASS_UNSPECIFIED {
            return QOS_CLASS_USER_INITIATED
        }
        return own.rawValue < QOS_CLASS_UTILITY.rawValue ? QOS_CLASS_UTILITY : own
    }

    /// Calls `body` once for every index below `count`, on the calling thread and the pool's, and returns when all are
    /// done.
    ///
    /// Calls made from inside `body` share the same threads.
    internal func run(count: Int, body: @escaping @Sendable (Int) -> Void) {
        let parent = current
        let job = Job(
            count: count,
            grain: max(1, count / ((width + 1) * 16)),
            parent: parent,
            body: body
        )
        let root = job.root
        condition.lock()
        open.append(job)
        // Whoever sleeps above this job can come and help with it.
        var ancestor = job.parent
        while let above = ancestor {
            above.sleeper?.signal()
            ancestor = above.parent
        }
        // Helpers the job can use: one per piece besides the caller's, as far as its tree may have them.
        let wanted = min(job.piecesLeft - 1, width, width + root.allowance - root.threads)
        var started = 0
        if wanted > 0 {
            let woken = summon(wanted)
            if woken < wanted {
                retiring = 0
                // Threads that were waiting at the last look leave their cores to new ones.
                // What the main thread waits for is not kept waiting for a core at all:
                // threads too many go again at the next look.
                let ready = threads - min(blocked, threads)
                started = max(0, min(wanted - woken, root.isForMain ? wanted : width - ready, limit - threads))
                threads += started
            }
        }
        // While there is work the threads are looked at, so that none of it is left lying.
        watch()
        condition.unlock()
        for _ in 0..<started { startThread() }

        work(on: job)
        // The caller's own pieces are done; others may still be at theirs.
        condition.lock()
        while job.inFlight > 0 {
            if let below = open.first(where: { $0.descends(from: job) }), let piece = take(from: below) {
                condition.unlock()
                perform(piece, of: below, countedFor: nil)
                condition.lock()
            } else {
                let sleeper = job.sleeper ?? DispatchSemaphore(value: 0)
                job.sleeper = sleeper
                condition.unlock()
                sleeper.wait()
                condition.lock()
            }
        }
        job.sleeper = nil
        // Nobody holds the closure any more: it must not outlive the call.
        job.body = nil
        condition.unlock()
    }

    deinit {
        // Nothing to release: a pool lives as long as its threads, which hold it.
    }
}
