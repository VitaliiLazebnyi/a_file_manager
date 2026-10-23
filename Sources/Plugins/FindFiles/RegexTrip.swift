import Foundation

/// Counts the regular expressions that ran out of time, so that a pattern which is too slow
/// for every name does not cost its time budget again for each of a million files: after a few
/// timeouts the pattern is taken as unusable and the rest answer at once.
///
/// Shared by the threads of one search. All state is guarded by `lock`.
internal final class RegexTrip: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts = 0
    private let limit: Int

    /// Whether any regular expression of the search ran out of time.
    internal var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts > 0
    }

    /// Whether enough of them did for the pattern to be given up.
    internal var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts >= limit
    }

    /// A counter that gives a pattern up after three timeouts.
    internal convenience init() {
        self.init(limit: 3)
    }

    /// A counter that gives a pattern up after `limit` timeouts.
    internal init(limit: Int) {
        self.limit = limit
    }

    /// Counts one more expression that ran out of time.
    internal func recordTimeout() {
        lock.lock()
        timeouts += 1
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
