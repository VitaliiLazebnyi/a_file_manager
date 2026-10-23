import Foundation

/// Counts the names a regular expression ran out of time on; shared by the threads that match
/// one mask.
///
/// After a few timeouts the expression is given up: the rest of the names answer at once instead of
/// costing the budget each.
///
/// All state is guarded by `lock`.
internal final class SelectionRegexTrip: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts = 0

    /// Whether a name has run out of time at least once (the mask then reports `timedOut`).
    internal var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts > 0
    }

    /// Whether the expression is given up: three names have run out of time.
    internal var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts >= 3
    }

    /// Counts one name that ran out of time; may be called from any thread.
    internal func recordTimeout() {
        lock.lock()
        timeouts += 1
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
