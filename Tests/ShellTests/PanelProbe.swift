import Foundation
import TestSupport

/// Counts the calls of a column's value function, from any thread, and notes whether any came
/// on the main thread, how many ran at once and in which order the entries were asked for.
///
/// Unchecked: what it counts is guarded by `condition`.
internal final class PanelProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var onMain = 0
    private var running = 0
    private var mostAtOnce = 0
    private var names: [String] = []
    private var waitsAt: Int?

    /// How many calls were made.
    internal var callCount: Int { condition.withLock { calls } }
    /// How many calls were made on the main thread.
    internal var callsOnMain: Int { condition.withLock { onMain } }
    /// The most calls that ran at the same time.
    internal var mostCallsAtOnce: Int { condition.withLock { mostAtOnce } }
    /// The entries the calls were made for, in the order the calls began.
    internal var noted: [String] { condition.withLock { names } }

    /// A probe that lets every call go on at once.
    internal init() {
        // Counts start at zero.
    }

    /// From now on the call that is the `number`th (counting from 1) waits until another call
    /// has begun beside it, for as long as `Wait.ceiling` at the most: whether calls overlap
    /// then does not depend on how fast a busy machine starts the next thread.
    internal func waitForCompany(atCall number: Int) {
        condition.withLock { waitsAt = number }
    }

    /// A call for the entry `name` begins.
    internal func enter(_ name: String) {
        condition.lock()
        defer { condition.unlock() }
        calls += 1
        names.append(name)
        if Thread.isMainThread {
            onMain += 1
        }
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        condition.broadcast()
        guard calls == waitsAt else {
            return
        }
        let mine = calls
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while calls == mine, condition.wait(until: end) {
            // Woken: look again.
        }
    }

    /// A call ends.
    internal func leave() {
        condition.withLock { running -= 1 }
    }

    deinit {
        // Nothing to release.
    }
}
