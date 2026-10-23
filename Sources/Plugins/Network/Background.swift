import Foundation

/// Where the work runs that waits for a server and that nobody waits for: the clean-up of an
/// abandoned transfer, the goodbye of a connection that is closed, the questions about links
/// after a listing, the keep-alive.
///
/// The thread that caused it (possibly the main thread) goes on at once.
///
/// A few threads of its own, not a dispatch queue: every piece of work may sit until a time
/// limit runs out when a server has stopped answering, and work that blocks on a dispatch
/// queue takes a thread from the pool the whole program shares. Here at most `mostThreads`
/// threads ever wait; what does not find a free one waits in line, so a dead server cannot
/// pile up threads however many transfers are dropped.
///
/// Work belongs to a lane (a session, a channel), and at most `mostPerLane` pieces of one
/// lane run at the same time: a server that has stopped answering holds up the work of its
/// own connection and never that of another server, whose connections would otherwise come
/// back to their pool only after the dead one's time limits.
internal enum Background {
    private struct Piece {
        let lane: ObjectIdentifier
        let work: @Sendable () -> Void
    }

    /// The most threads that ever run background work at the same time.
    internal static let mostThreads = 24
    /// The most pieces of one lane that run at the same time.
    internal static let mostPerLane = 3

    private static let condition = NSCondition()
    /// Guarded by `condition`.
    nonisolated(unsafe) private static var waiting: [Piece] = []
    /// Guarded by `condition`.
    nonisolated(unsafe) private static var threads = 0
    /// Guarded by `condition`.
    nonisolated(unsafe) private static var idle = 0
    /// Guarded by `condition`.
    nonisolated(unsafe) private static var runningIn: [ObjectIdentifier: Int] = [:]
    /// Guarded by `condition`.
    nonisolated(unsafe) private static var waitingIn: [ObjectIdentifier: Int] = [:]

    /// The threads that exist right now, for tests.
    internal static var threadCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return threads
    }

    /// Runs `work` on a background thread as soon as one is free and its lane has room; returns at once.
    ///
    /// `owner` names the lane: the session or channel whose server the work waits for.
    internal static func run(lane owner: AnyObject, _ work: @escaping @Sendable () -> Void) {
        let lane = ObjectIdentifier(owner)
        condition.lock()
        waiting.append(Piece(lane: lane, work: work))
        waitingIn[lane, default: 0] += 1
        if idle > 0 {
            // Every sleeper looks: the one that is woken must be one that may take this piece.
            condition.broadcast()
        } else if threads < mostThreads, runningIn[lane, default: 0] < mostPerLane {
            threads += 1
            let thread = Thread { Self.serve() }
            thread.name = "afm.network.background"
            thread.qualityOfService = .utility
            thread.start()
        }
        condition.unlock()
    }

    /// Waits until nothing of this lane is running or waiting, `timeout` seconds at most; for tests.
    ///
    /// Returns false when the time ran out first.
    @discardableResult
    internal static func waitUntilIdle(lane owner: AnyObject, timeout: TimeInterval) -> Bool {
        let lane = ObjectIdentifier(owner)
        return wait(timeout) { runningIn[lane] == nil && waitingIn[lane] == nil }
    }

    /// The first piece in line whose lane has room.
    ///
    /// Called with the lock held.
    private static func takeNext() -> Piece? {
        guard
            let index = waiting.firstIndex(where: { piece in runningIn[piece.lane, default: 0] < mostPerLane })
        else { return nil }
        let piece = waiting.remove(at: index)
        runningIn[piece.lane, default: 0] += 1
        waitingIn[piece.lane] = waitingIn[piece.lane].flatMap { $0 > 1 ? $0 - 1 : nil }
        return piece
    }

    private static func serve() {
        condition.lock()
        var waitedInVain = false
        var next = takeNext()
        // A thread that waited in vain looks once more, then ends: what may still wait is
        // behind its own lane's limit, and the threads of that lane take it.
        while next != nil || !waitedInVain {
            if let piece = next {
                condition.unlock()
                piece.work()
                condition.lock()
                runningIn[piece.lane] = runningIn[piece.lane].flatMap { $0 > 1 ? $0 - 1 : nil }
                condition.broadcast()
                waitedInVain = false
            } else {
                idle += 1
                waitedInVain = !condition.wait(until: Date().addingTimeInterval(10))
                idle -= 1
            }
            next = takeNext()
        }
        threads -= 1
        condition.unlock()
    }

    private static func wait(_ timeout: TimeInterval, until isDone: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isDone() {
            guard Date() < deadline else {
                return false
            }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        return true
    }
}
