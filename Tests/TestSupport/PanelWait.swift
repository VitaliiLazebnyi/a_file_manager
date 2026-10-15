public import Foundation

/// Waits in tests that run on the main thread for what the main thread itself makes true: work
/// that arrives through the main queue or the run loop (`MainLoop`), as a panel's does.
///
/// `Wait` blocks the calling thread, so it cannot wait for the main thread from the main thread.
/// These waits suspend the test between looks and leave the main thread free to work meanwhile.
@MainActor
public enum PanelWait {
    /// Asks `condition` every couple of milliseconds, with the main thread free in between,
    /// until it holds.
    ///
    /// Returns false when it still does not after `seconds`: a hang, to be reported as a failure.
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

    /// Lets `seconds` pass with the main thread free, for checks that something does not happen
    /// within a time the program promises.
    public static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Lets everything the main queue holds now run, and what that sends to the main queue in turn
    /// once more.
    public static func drainMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
    }
}
