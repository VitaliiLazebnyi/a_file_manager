import AFMKernel
import Foundation

/// Counts the names a regular expression of Search & Replace ran out of time on.
///
/// Shared by the threads of one preview or run. After a few timeouts the expression is given up:
/// the rest of the names answer at once (`<Error!>`) instead of costing the budget each.
///
/// Unchecked `Sendable`: `timeouts` is guarded by `lock`.
internal final class RenameRegexGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts = 0
    private let limit = 3

    /// Whether any name took too long.
    internal var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts > 0
    }

    /// Whether enough names did for the expression to be given up.
    internal var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeouts >= limit
    }

    /// Counts one more name that took too long.
    internal func recordTimeout() {
        lock.lock()
        timeouts += 1
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
