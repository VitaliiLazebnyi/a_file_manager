public import Foundation

/// Waits on the main thread for work that is handed to it: blocks of the main queue, which run
/// while the test is suspended, and blocks handed to the main run loop, which run while the
/// loop is run here.
@MainActor
public enum RunLoopWait {
    /// Lets the main thread work until `condition` holds; false when it still does not after
    /// `seconds`: a hang, to be reported as a failure.
    public static func until(seconds: TimeInterval = Wait.ceiling, _ condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end {
                return false
            }
            runPendingBlocks()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// Runs what was handed to the main run loop and is due, without waiting.
    public static func runPendingBlocks() {
        RunLoop.main.run(mode: .default, before: Date())
    }
}
