import AFMKernel
import Foundation

/// The pool: handing out connections, taking them back, and running work on them.
extension FTPSession {
    /// One thread's wait for a connection: what it is for, and what the server said when it had no room
    /// for another one.
    internal struct PoolWait {
        /// What the connection is held for while a file is open; nil for commands.
        internal let transfer: TransferKind?
        /// A new connection is wanted, not an idle one.
        internal let fresh: Bool
        /// Work in the background never waits, and opens no connection that would ask the user.
        internal let background: Bool
        /// Ends the wait.
        internal let cancellation: CancellationFlag?
        /// When the wait began.
        internal let began: Date
        /// After the server said it has no room for another connection (421): when to ask again.
        internal var openNotBefore: Date?
        /// How often the server was asked again after a 421.
        internal var busyRetries = 0
        /// What the server said the last time it had no room.
        internal var busyReply: FTPReply?

        /// Whether the thread counts as a command that waits (see `commandWaiters`).
        internal var isCommand: Bool { transfer == nil && !background }
    }

    /// What a wait for a connection found.
    private enum Slot {
        /// An idle connection of the pool.
        case idle(FTPConnection)
        /// Room for a new connection, already counted in `total`.
        case open
    }

    /// Hands out a connection.
    ///
    /// A `transfer` connection is kept for as long as a file is open.
    ///
    /// Every wait in here ends: when `cancellation` is set, when the session is closed, and when
    /// nothing has moved on any connection for `patience` seconds (then with an error that says
    /// what is in the way). `background` work never waits at all: it takes a connection that is
    /// free now, or fails.
    internal func acquire(
        transfer: TransferKind?,
        fresh: Bool,
        background: Bool,
        cancellation: CancellationFlag?
    ) throws -> (connection: FTPConnection, reused: Bool) {
        var wait = PoolWait(
            transfer: transfer,
            fresh: fresh,
            background: background,
            cancellation: cancellation,
            began: Date()
        )
        let acquired: (connection: FTPConnection, reused: Bool)
        acquiring: while true {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            switch try takeSlot(wait) {
            case .idle(let connection):
                // A connection that sat idle may have been dropped by the server or a router.
                if environment.clock().timeIntervalSince(connection.lastUsed) > Self.trustedIdleTime,
                    !connection.isAlive(cancellation: cancellation ?? closing)
                {
                    discard(connection, wasInUse: false, transfer: transfer)
                    continue
                }
                register(connection)
                acquired = (connection, true)
                break acquiring

            case .open:
                do {
                    let connection = try openConnection(cancellation: cancellation, background: background)
                    register(connection)
                    acquired = (connection, false)
                    break acquiring
                } catch {
                    try giveSlotBack(after: error, &wait)
                }
            }
        }
        return acquired
    }

    /// Takes a connection back; one that is no longer usable is closed.
    internal func release(_ connection: FTPConnection, transfer: TransferKind?) {
        condition.lock()
        inUse[ObjectIdentifier(connection)] = nil
        if let transfer { adjust(transfer, by: -1) }
        let keep = connection.isUsable && !isClosed
        if keep {
            idle.append(connection)
        } else {
            total -= 1
        }
        lastProgress = Date()
        condition.broadcast()
        condition.unlock()
        if !keep { connection.close() }
    }

    /// Runs a command sequence on a connection of the pool.
    ///
    /// When a connection that was idle turns out to be dead, the work is done once more on a new
    /// one (spec: reconnect on a dropped control connection). `mayRetry` is asked first, because
    /// work that already had an effect outside must not be repeated. A `transfer` connection stays
    /// in the caller's hands when the work succeeds.
    internal func perform<Result>(
        transfer: TransferKind?,
        cancellation: CancellationFlag?,
        mayRetry: (FTPConnection) -> Bool,
        work: (FTPConnection) throws -> Result
    ) throws -> (result: Result, connection: FTPConnection) {
        var (connection, reused) = try acquire(
            transfer: transfer,
            fresh: false,
            background: false,
            cancellation: cancellation
        )
        let result: Result
        attempt: while true {
            do {
                result = try work(connection)
                if transfer == nil { release(connection, transfer: nil) }
                break attempt
            } catch {
                guard let failure = error as? NetworkError, failure.isConnectionLevel, reused, !connection.isUsable,
                    mayRetry(connection)
                else {
                    release(connection, transfer: transfer)
                    throw error
                }
                discard(connection, wasInUse: true, transfer: transfer)
                (connection, reused) = (
                    try acquire(transfer: transfer, fresh: true, background: false, cancellation: cancellation)
                        .connection,
                    false
                )
            }
        }
        return (result, connection)
    }

    /// A command, or a few that belong together.
    ///
    /// One that must not happen twice (it creates, removes or renames) is repeated on a new
    /// connection only when the old one failed before the command was sent, or the server said it
    /// was closing (421): after a reply that did not come, the command may well have been carried
    /// out.
    internal func command<Result>(
        repeatable: Bool,
        cancellation: CancellationFlag?,
        _ work: (FTPConnection) throws -> Result
    ) throws -> Result {
        try perform(
            transfer: nil,
            cancellation: cancellation,
            mayRetry: { connection in repeatable || !connection.commandMayHaveRun },
            work: work
        )
        .result
    }

    /// A transfer: `work` starts it on a connection that is then held for the open file.
    internal func transfer<Result>(
        _ kind: TransferKind,
        cancellation: CancellationFlag?,
        _ work: (FTPConnection) throws -> Result
    ) throws -> (result: Result, connection: FTPConnection) {
        try perform(transfer: kind, cancellation: cancellation, mayRetry: { _ in true }, work: work)
    }

    /// Waits until an idle connection, or room for a new one, is there for this thread, and takes it
    /// (a transfer's slot too).
    private func takeSlot(_ wait: PoolWait) throws -> Slot {
        condition.lock()
        if wait.isCommand { commandWaiters += 1 }
        let slot: Slot
        waiting: while true {
            let found: Slot?
            do {
                found = try lookForSlot(wait)
            } catch {
                if wait.isCommand { commandWaiters -= 1 }
                condition.broadcast()
                condition.unlock()
                throw error
            }
            if let found {
                slot = found
                break waiting
            }
            condition.wait(until: Date().addingTimeInterval(returning > 0 || pinged != nil ? 0.05 : 0.2))
        }
        if wait.isCommand { commandWaiters -= 1 }
        // The slot is taken now, not when the connection is registered, so threads that
        // arrive together do not all see it free.
        if let transfer = wait.transfer { adjust(transfer, by: 1) }
        lastActivity = environment.clock()
        condition.unlock()
        return slot
    }

    /// A slot for the wait, nil when it goes on; throws when it must end: the session is closed, the
    /// work is in the background, the caller cancelled, or nothing moves.
    ///
    /// Called with the lock held.
    private func lookForSlot(_ wait: PoolWait) throws -> Slot? {
        let server = currentProfile.key.description
        if isClosed { throw NetworkError.notConnected(server) }
        let limit = max(1, environment.options.values.parallelConnections)
        let hasSlot = wait.transfer.map { holders(of: $0) < limit + Self.extraTransferConnections } ?? true
        if hasSlot, let slot = takeFreeSlot(wait, limit: limit) {
            return slot
        }
        if wait.background { throw NetworkError.busy("No connection to \(server) is free.") }
        if wait.cancellation?.isCancelled == true { throw NetworkError.cancelled }
        if let error = stalled(since: wait.began, whatIsInTheWay(hasSlot: hasSlot, transfer: wait.transfer)) {
            throw wait.busyReply.map { NetworkError.refused($0) } ?? error
        }
        return nil
    }

    /// An idle connection, or room for a new one (counted in `total` here); nil when the thread must wait.
    ///
    /// Called with the lock held, when the transfer (if any) has a free slot.
    private func takeFreeSlot(_ wait: PoolWait, limit: Int) -> Slot? {
        if !wait.fresh, let connection = idle.popLast() {
            return .idle(connection)
        }
        let serverHasRoom =
            wait.busyRetries <= Self.busyDelays.count && (wait.openNotBefore.map { Date() >= $0 } ?? true)
        // A connection that is on its way back is waited for, for a moment.
        let oneIsComing =
            (returning > 0 || pinged != nil) && !wait.fresh && Date().timeIntervalSince(wait.began) < grace
        // Connections held by open files are not coming back soon, and one the keep-alive tests is nobody's.
        guard serverHasRoom, !oneIsComing,
            wait.transfer != nil || total - transfers - (pinged == nil ? 0 : 1) < limit || wait.fresh
        else {
            return nil
        }
        total += 1
        return .open
    }

    /// What a wait that stalled was waiting for, for its error.
    ///
    /// Called with the lock held.
    private func whatIsInTheWay(hasSlot: Bool, transfer: TransferKind?) -> String {
        let server = currentProfile.key.description
        if hasSlot {
            return "All connections to \(server) are in use and none came free."
        }
        let files = transfer == .read ? "downloads" : "uploads"
        return "All connections to \(server) for \(files) are held by open files."
    }

    /// Gives back the slot of a connection that could not be opened.
    ///
    /// Throws `error`, unless the
    /// server said it has no room (421) after an earlier login: then this thread takes a connection
    /// that comes free, or asks the server again after a while; when the server keeps saying no,
    /// only the former.
    private func giveSlotBack(after error: any Error, _ wait: inout PoolWait) throws {
        condition.lock()
        total -= 1
        if let transfer = wait.transfer { adjust(transfer, by: -1) }
        var again = false
        if case NetworkError.refused(let reply) = error, reply.code == 421, hasConnected, !isClosed, !wait.background {
            wait.busyReply = reply
            if wait.busyRetries < Self.busyDelays.count {
                wait.openNotBefore = Date().addingTimeInterval(Self.busyDelays[wait.busyRetries])
            }
            wait.busyRetries += 1
            again = true
        }
        condition.broadcast()
        condition.unlock()
        if !again { throw error }
    }

    /// How many connections are held for files of this kind.
    ///
    /// Called with the lock held.
    private func holders(of kind: TransferKind) -> Int { kind == .read ? readers : writers }

    /// Counts connections held for files of this kind; called with the lock held.
    private func adjust(_ kind: TransferKind, by change: Int) {
        if kind == .read { readers += change } else { writers += change }
    }

    /// Notes a connection as handed out; one opened while the session was closed is cut.
    private func register(_ connection: FTPConnection) {
        condition.lock()
        inUse[ObjectIdentifier(connection)] = connection
        let closed = isClosed
        condition.unlock()
        // Disconnected while this connection was being opened.
        if closed { connection.interrupt() }
    }

    /// Closes a connection and gives up its place in the pool (and its transfer slot, if any).
    private func discard(_ connection: FTPConnection, wasInUse: Bool, transfer: TransferKind?) {
        condition.lock()
        if wasInUse { inUse[ObjectIdentifier(connection)] = nil }
        if let transfer { adjust(transfer, by: -1) }
        total -= 1
        condition.broadcast()
        condition.unlock()
        connection.close()
    }
}
