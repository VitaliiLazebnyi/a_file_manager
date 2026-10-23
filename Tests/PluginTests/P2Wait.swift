import AFMKernel
import Foundation

/// Waits for work under test that may hang on a file system that stopped answering, and stops it from outside.
internal enum P2Wait {
    /// How long work is given before it counts as hung.
    ///
    /// The time only matters when the code under test hangs, which is the failure the test is there to catch.
    private static let patience: TimeInterval = 60

    /// Runs `work` on another thread and waits for it; if it does not end in time, `rescue` is called (to free
    /// whatever it hangs on) and false comes back.
    internal static func finishes(rescue: (() -> Void)?, work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        if done.wait(timeout: .now() + patience) == .success {
            return true
        }
        rescue?()
        _ = done.wait(timeout: .now() + 10)
        return false
    }

    /// Sets `flag` `seconds` from now, from a thread of its own (not from a shared queue, whose
    /// threads other tests may all be holding).
    ///
    /// The moment only has to be after the work under test has begun to wait; if it is not, the work
    /// finds the flag set and ends just the same.
    internal static func cancel(_ flag: CancellationFlag, after seconds: TimeInterval) {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            flag.cancel()
        }
    }
}
