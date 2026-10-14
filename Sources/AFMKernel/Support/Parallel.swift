import Foundation

/// Spreads independent work over the processor's cores.
public enum Parallel {
    /// Transforms every element, using all cores, and returns the results in the original
    /// order. `transform` runs on several threads at once and must not touch shared state
    /// without protecting it. Short inputs are done on the calling thread.
    ///
    /// Calls may be nested: a transform that calls `map` itself (a walk through a tree of
    /// folders) shares the same threads, so the work below the top level is spread over the
    /// cores as well, and the number of threads stays bounded however deep the calls go.
    ///
    /// **A call made on the main thread must not hop to the main thread.** The main thread
    /// waits inside `map` until every element is done, so a transform that waits for it in
    /// turn (`DispatchQueue.main.sync`, `Kernel.askUser`, anything that asks the user) never
    /// returns: the program hangs, or stops with a trap when the hop is tried on the main
    /// thread itself. That holds for everything the transform calls, nested `map`s included.
    /// Work that may have to ask the main thread is started from a background thread. Code
    /// that is about to wait for the main thread says so with
    /// `Parallel.assertMayWaitForMainThread()`, which stops a wrong caller in debug builds.
    ///
    /// Every piece of the work runs inside an autorelease pool of its own, on whatever thread
    /// it runs: what a transform leaves to be released later (data read through Foundation)
    /// is gone when the piece ends.
    public static func map<Element, Result>(
        _ items: [Element], serialBelow threshold: Int = 2,
        _ transform: (Element) -> Result
    ) -> [Result] {
        guard items.count >= threshold, items.count > 1, ParallelPool.shared.width > 0 else {
            return items.map(transform)
        }
        return [Result](unsafeUninitializedCapacity: items.count) { buffer, count in
            // Each iteration writes its own slot, so the slots need no lock.
            let slots = UnsafeMutablePointer<Result>(buffer.baseAddress!)
            items.withUnsafeBufferPointer { source in
                withoutActuallyEscaping(transform) { transform in
                    ParallelPool.shared.run(count: source.count) { index in
                        (slots + index).initialize(to: transform(source[index]))
                    }
                }
            }
            count = items.count
        }
    }

    /// True while the calling code runs as part of a `map` that the main thread is waiting
    /// for (on the main thread itself or on one of the helping threads): waiting for the
    /// main thread from here would never end.
    public static var isHoldingUpMainThread: Bool { ParallelPool.shared.isWorkingForMainThread }

    /// To be called by whatever is about to wait for the main thread (before
    /// `DispatchQueue.main.sync`): stops, in debug builds, a caller that is part of a `map`
    /// the main thread waits for (see `map`).
    public static func assertMayWaitForMainThread(file: StaticString = #fileID, line: UInt = #line) {
        assert(
            !isHoldingUpMainThread,
            "Work inside a Parallel.map that was called on the main thread must not wait for the main thread",
            file: file, line: line)
    }
}

/// The threads behind `Parallel.map`. Every call opens a job: a range of indexes that the
/// caller and the pool's threads take pieces of until none is left. A thread that runs out of
/// pieces while others still work on its job does not sleep if it can help it: it takes pieces
/// of the jobs that were opened below its own (the nested calls), which is work its own job is
/// waiting for anyway. It never takes unrelated work, so a call returns as soon as its own
/// work is done, and it never waits for a thread that has not started, so nesting cannot
/// deadlock.
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
final class ParallelPool {
    static let shared = ParallelPool()

    /// Helper threads besides the callers themselves.
    let width = max(0, ProcessInfo.processInfo.activeProcessorCount - 1)
    /// The most threads one tree can have, counting those it is given because its pieces wait.
    private var treeLimit: Int { width * 4 }
    /// The most threads there can ever be.
    private var limit: Int { max(64, width * 16) }
    /// How often the threads are looked at while there is work, in nanoseconds…
    private static let patience: UInt64 = 20_000_000
    /// …and how seldom when looking has stopped changing anything.
    private static let longestPatience: UInt64 = 1_000_000_000

    private final class Job {
        var body: ((Int) -> Void)?
        let count: Int
        /// Indexes taken in one piece: large inputs are handed out in runs, so the lock is
        /// not taken for every element.
        let grain: Int
        var next = 0
        /// Pieces being worked on.
        var inFlight = 0
        /// The job whose piece was running on the thread that opened this one.
        let parent: Job?
        /// The top of the tree this job belongs to; nil for the top itself.
        private let top: Job?
        /// Signalled when the caller sleeps until the last piece is done or work appears below.
        var sleeper: DispatchSemaphore?

        // What follows is kept by the top of a tree, for the whole tree.
        /// The main thread waits for this tree.
        let isForMain: Bool
        /// The urgency of whoever opened the tree, which the pool's threads take on for its pieces.
        let urgency: qos_class_t
        /// The pool's threads that are at a piece of this tree.
        var threads = 0
        /// Threads beyond the cores that the tree may have, because its pieces wait and get done.
        var allowance = 0
        /// Pieces done so far, and how many of them the last look knew of.
        var finished = 0, seenFinished = 0
        /// Scratch for a look: the threads the tree could still take.
        var room = 0

        init(
            count: Int, grain: Int, parent: Job?, isForMain: Bool, urgency: qos_class_t, body: @escaping (Int) -> Void
        ) {
            (self.count, self.grain, self.parent, self.body) = (count, grain, parent, body)
            top = parent.map(\.root)
            (self.isForMain, self.urgency) = (isForMain, urgency)
        }

        var root: Job { top ?? self }
        var piecesLeft: Int { (count - next + grain - 1) / grain }

        func descends(from ancestor: Job) -> Bool {
            var current = parent
            while let job = current {
                if job === ancestor { return true }
                current = job.parent
            }
            return false
        }
    }

    /// Guards everything below, and the counters of every job.
    private let condition = NSCondition()
    /// Jobs with pieces left, oldest first: within a tree the oldest are the nearest to its
    /// top, and their pieces are the largest.
    private var open: [Job] = []
    private var threads = 0
    private var idle = 0
    /// Idle threads that were called to work and have not come round yet. An idle thread
    /// waits for this number to be above zero, not for the signal that goes with it: a signal
    /// that finds nobody waiting is lost, a number is not.
    private var summons = 0
    /// For how long a thread with nothing to do stays, in seconds.
    private var linger: TimeInterval = 2
    /// The same for tests, which make it short.
    var lingering: TimeInterval {
        get {
            condition.lock()
            defer { condition.unlock() }
            return linger
        }
        set {
            condition.lock()
            linger = newValue
            condition.unlock()
        }
    }
    /// Threads that are to leave when they next look for work: more are ready to run than
    /// there are cores.
    private var retiring = 0
    /// The pool's threads: the processor time each had used when last looked at, and the tree
    /// it is at a piece of.
    private var workers: [thread_t: (used: UInt64, tree: Job?)] = [:]
    /// How many of the threads were waiting rather than computing at the last look.
    private var blocked = 0
    private var isWatching = false
    private var hasWatcher = false
    /// The pause before the next look.
    private var interval = ParallelPool.patience
    /// Wakes the watching thread: to start watching, or to look sooner than it meant to.
    private let watcherWake = DispatchSemaphore(value: 0)
    /// The job whose piece runs on the current thread, kept with the thread. The job is
    /// not retained here: it outlives every one of its pieces.
    private static let currentJob: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    private var current: Job? {
        get { pthread_getspecific(Self.currentJob).map { Unmanaged<Job>.fromOpaque($0).takeUnretainedValue() } }
        set {
            pthread_setspecific(
                Self.currentJob, newValue.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) })
        }
    }

    /// Whether the calling thread is at a piece of a tree the main thread waits for.
    var isWorkingForMainThread: Bool { current?.root.isForMain ?? false }

    /// The pool's threads as they are now; for tests.
    var census: (threads: Int, idle: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (threads, idle)
    }

    /// The urgency the pool's threads work with for a caller: the caller's own, but never so
    /// low that the system may leave the work lying for long.
    private static func urgencyOfCaller() -> qos_class_t {
        let own = qos_class_self()
        if own == QOS_CLASS_UNSPECIFIED { return QOS_CLASS_USER_INITIATED }
        return own.rawValue < QOS_CLASS_UTILITY.rawValue ? QOS_CLASS_UTILITY : own
    }

    func run(count: Int, body: @escaping (Int) -> Void) {
        let parent = current
        let job = Job(
            count: count, grain: max(1, count / ((width + 1) * 16)), parent: parent,
            isForMain: parent == nil && Thread.isMainThread,
            urgency: parent == nil ? Self.urgencyOfCaller() : QOS_CLASS_UNSPECIFIED,
            body: body)
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
                perform(piece, of: below)
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

    // MARK: Watching

    /// Has the threads looked at soon, and again for as long as there is work or a thread too
    /// many. Called with the lock held.
    private func watch() {
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

    /// Calls up to `wanted` idle threads to work and returns how many were called. Called
    /// with the lock held.
    private func summon(_ wanted: Int) -> Int {
        let called = min(max(0, idle - summons), wanted)
        guard called > 0 else { return 0 }
        summons += called
        if called == 1 { condition.signal() } else { condition.broadcast() }
        return called
    }

    /// Looks at the threads: one that is at a piece but has hardly used the processor since
    /// the last look is waiting for something and leaves its core free. Work that nobody
    /// takes then gets idle or new threads, as far as its tree may have them, and threads
    /// beyond the cores that are ready to run are told to go. Returns the number of threads
    /// to start, which are counted already.
    private func look() -> Int {
        condition.lock()
        defer { condition.unlock() }
        var waiting = 0
        var waitingIn: [ObjectIdentifier: Int] = [:]
        for (thread, state) in workers {
            let (time, isRunnable) = Self.processorTime(of: thread) ?? (state.used, true)
            // A thread that the machine has no core for is not waiting for anything.
            if let tree = state.tree, !isRunnable, time &- state.used < Self.patience / 4 {
                waiting += 1
                waitingIn[ObjectIdentifier(tree), default: 0] += 1
            }
            workers[thread]?.used = time
        }
        blocked = waiting
        var changed = false
        // The pieces that threads could be put to.
        var demand = 0
        var seen = Set<ObjectIdentifier>()
        for job in open {
            let root = job.root
            if seen.insert(ObjectIdentifier(root)).inserted {
                // A tree whose threads wait and whose pieces get done all the same is waiting
                // for answers that come: more threads make it faster. One whose pieces do not
                // get done keeps what it has.
                if root.finished != root.seenFinished {
                    root.seenFinished = root.finished
                    let stuck = waitingIn[ObjectIdentifier(root)] ?? 0
                    if stuck > 0, root.threads >= width + root.allowance, root.allowance < treeLimit - width {
                        root.allowance = min(treeLimit - width, root.allowance + stuck)
                        changed = true
                    }
                }
                root.room = max(0, width + root.allowance - root.threads)
            }
            let given = min(job.piecesLeft, root.room)
            root.room -= given
            demand += given
        }
        let woken = summon(demand)
        let ready = threads - min(waiting, threads)
        let starts = max(0, min(demand - woken, width - ready, limit - threads))
        threads += starts
        // More threads ready to run than cores, the idle ones among them: the stall that
        // made them is over.
        retiring = starts > 0 ? 0 : max(0, ready - width - woken)
        if retiring > 0, idle > 0 { condition.broadcast() }
        changed = changed || starts > 0 || woken > 0 || retiring > 0
        interval = changed ? Self.patience : min(interval * 2, Self.longestPatience)
        if open.isEmpty, threads <= width { isWatching = false }
        return starts
    }

    /// The processor time a thread has used so far, in nanoseconds, and whether it is ready to
    /// run (as opposed to blocked).
    private static func processorTime(of thread: thread_t) -> (used: UInt64, isRunnable: Bool)? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { info in
            info.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let seconds = UInt64(info.user_time.seconds) + UInt64(info.system_time.seconds)
        let microseconds = UInt64(info.user_time.microseconds) + UInt64(info.system_time.microseconds)
        return (seconds * 1_000_000_000 + microseconds * 1_000, info.run_state == TH_STATE_RUNNING)
    }

    // MARK: Pieces

    /// Takes the next piece of a job. Called with the lock held.
    private func take(from job: Job) -> Range<Int>? {
        guard job.next < job.count else { return nil }
        let piece = job.next..<min(job.next + job.grain, job.count)
        job.next = piece.upperBound
        job.inFlight += 1
        if job.next == job.count, let index = open.firstIndex(where: { $0 === job }) { open.remove(at: index) }
        return piece
    }

    /// The job a free thread of the pool takes a piece of: of the trees that may have another
    /// thread, the one the main thread waits for, else the one with the fewest threads; within
    /// a tree the oldest job. Called with the lock held.
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

    /// Runs a piece on this thread. Called without the lock. `tree` is the tree a thread of
    /// the pool was counted for when it took the piece.
    private func perform(_ piece: Range<Int>, of job: Job, countedFor tree: Job? = nil) {
        let outer = current
        current = job
        // The closure is only borrowed for the piece: it is let go before the piece counts as
        // done. What the work leaves to be released later is released with the piece, and not
        // when the thread ends, which may be never.
        do {
            let body = job.body!
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

    private func work(on job: Job) {
        while true {
            condition.lock()
            let piece = take(from: job)
            condition.unlock()
            guard let piece else { return }
            perform(piece, of: job)
        }
    }

    private func startThread() {
        let thread = Thread { [self] in
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
        thread.name = "AFM.Parallel"
        thread.qualityOfService = .userInitiated
        // Room for work that goes deep (a walk calls itself for every level of folders).
        thread.stackSize = 2 << 20
        thread.start()
    }
}

/// States which thread a piece of state belongs to. Panel state, the registries and everything
/// on screen belong to the main thread; these checks stop a wrong caller in debug builds.
public enum MainThread {
    public static func assert(
        _ what: @autoclosure () -> String = "This", file: StaticString = #fileID, line: UInt = #line
    ) {
        Swift.assert(Thread.isMainThread, "\(what()) must be used on the main thread", file: file, line: line)
    }
}

/// The processor time a thread has used, for a limit on how much **work** something may take.
/// Such a limit must not be measured by the clock: on a machine where more threads want to
/// run than there are cores, a thread stands still for long stretches, and a search that
/// allows a regular expression a quarter of a second "of time" then gives up on names it
/// would have matched in a millisecond. The answer would depend on how busy the machine is.
public enum ThreadTime {
    /// Seconds of processor time the calling thread has used so far.
    public static var used: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }
}
