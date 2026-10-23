import AFMKernel
import Foundation

/// The keep-alive of the idle connections.
extension FTPSession {
    /// Sends NOOP on idle connections so the server does not close them, and closes the spare
    /// ones after a while to free the server's slots.
    internal func startKeepAlive() {
        let interval = environment.options.values.keepAliveInterval
        condition.lock()
        defer { condition.unlock() }
        guard keepAlive == nil, interval > 0, !isClosed else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: keepAliveQueue)
        let period = max(0.25, interval / 2)
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler { [weak self] in self?.keepAliveBeat(interval: interval) }
        timer.resume()
        keepAlive = timer
    }

    /// The timer only says when: the test waits for the server, which a dispatch queue must not,
    /// so it runs in the background, one round at a time.
    private func keepAliveBeat(interval: TimeInterval) {
        condition.lock()
        let start = !isPinging && !isClosed
        if start { isPinging = true }
        condition.unlock()
        if start {
            Background.run(lane: self) { [weak self] in self?.keepIdleConnectionsAlive(interval: interval) }
        }
    }

    /// Tests the idle connections that were not used for `interval`, one at a time: each is
    /// taken out of the pool for its test only, and while it is out it does not count against
    /// the limit, so a command never waits for a test to end.
    private func keepIdleConnectionsAlive(interval: TimeInterval) {
        var kept = 0
        var tested = Set<ObjectIdentifier>()
        while true {
            let now = environment.clock()
            condition.lock()
            guard !isClosed,
                let index = idle.firstIndex(where: { connection in
                    now.timeIntervalSince(connection.lastUsed) >= interval
                        && !tested.contains(ObjectIdentifier(connection))
                })
            else {
                isPinging = false
                condition.unlock()
                break
            }
            let connection = idle.remove(at: index)
            tested.insert(ObjectIdentifier(connection))
            pinged = connection
            let resting = now.timeIntervalSince(lastActivity)
            // One connection is kept warm for an hour; the others go when nothing has happened for a while.
            let isTheOne = idle.isEmpty && kept == 0
            condition.unlock()
            let wanted = isTheOne ? resting < Self.keepAliveLimit : resting < max(120, interval * 2)
            let alive = wanted && connection.isAlive(cancellation: closing)
            condition.lock()
            pinged = nil
            let keep = alive && !isClosed
            if keep {
                idle.append(connection)
                kept += 1
            } else {
                total -= 1
            }
            condition.broadcast()
            condition.unlock()
            if !keep { connection.close() }
        }
    }
}
