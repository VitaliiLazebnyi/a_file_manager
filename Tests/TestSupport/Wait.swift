public import Foundation

/// Waits for conditions that other threads make true, never for a length of time alone.
public enum Wait {
    /// The longest any wait lasts: far longer than anything takes on a busy machine or under a
    /// sanitizer, so only a hang reaches it, and then the test fails instead of hanging the run.
    public static let ceiling: TimeInterval = 300

    /// Asks `condition` on the calling thread, every couple of milliseconds, until it holds.
    ///
    /// Returns false when it still does not after `seconds`: a hang, to be reported as a failure.
    public static func until(seconds: TimeInterval = ceiling, _ condition: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end {
                return false
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return true
    }
}
