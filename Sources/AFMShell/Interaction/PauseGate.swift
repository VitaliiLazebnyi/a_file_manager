import AFMKernel
import Foundation

/// Where a paused job waits.
///
/// Safe to use from any thread: the state is guarded by `condition`.
internal final class PauseGate: @unchecked Sendable {
    /// Guards `paused` and wakes the job when it changes.
    private let condition = NSCondition()
    /// True while the job is to wait.
    private var paused = false

    /// Whether the job is held; any thread.
    internal var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    /// An open gate.
    internal init() {
        // Jobs start running.
    }

    /// Holds the job at its next report, or lets it go on; any thread.
    internal func set(paused: Bool) {
        condition.lock()
        self.paused = paused
        condition.broadcast()
        condition.unlock()
    }

    /// Lets the job pass, waiting while it is paused; called on the job's thread.
    ///
    /// Returns at once unless the job is paused, and then when it is resumed or cancelled. The
    /// cancellation is also looked at every now and then, because the flag can be set by anyone
    /// without telling the gate.
    internal func passWhenOpen(_ cancellation: CancellationFlag) {
        condition.lock()
        while paused, !cancellation.isCancelled {
            condition.wait(until: Date().addingTimeInterval(0.1))
        }
        condition.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
