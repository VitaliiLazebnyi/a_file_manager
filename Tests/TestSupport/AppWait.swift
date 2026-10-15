public import Foundation

/// Waits for what the program does on the main thread, with the main thread free to do it.
///
/// A test of the window shell runs on the main actor, where the panels, the jobs and the
/// dialogs also do their work. `Wait.until` would hold the thread while it asks; spinning the
/// run loop from inside a test does not do either, because the main queue is not drained
/// re-entrantly. These waits suspend between the questions instead.
public enum AppWait {
    /// Asks `condition` on the main thread, every couple of milliseconds, until it holds.
    ///
    /// Returns false when it still does not after `seconds`: a hang, to be reported as a failure.
    @MainActor
    @discardableResult
    public static func until(seconds: TimeInterval = Wait.ceiling, _ condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }
}
