import AFMKernel
import Foundation

/// A value one thread waits for and another delivers.
///
/// Safe from any thread.
///
/// All state is guarded by `condition`.
internal final class Pending<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?

    /// Delivers the value and wakes the waiters; a value that is there already stays.
    internal func fulfill(_ value: Value) {
        condition.lock()
        if self.value == nil { self.value = value }
        condition.broadcast()
        condition.unlock()
    }

    /// The value when it is there already; never waits.
    internal func poll() -> Value? {
        condition.lock()
        defer { condition.unlock() }
        return value
    }

    /// Nil when the time is up.
    ///
    /// A set cancellation flag ends the wait with `NetworkError.cancelled`.
    internal func wait(timeout: TimeInterval, cancellation: CancellationFlag?) throws -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while value == nil {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            let now = Date()
            if now >= deadline {
                return nil
            }
            // Woken a few times a second to notice a cancellation.
            condition.wait(until: min(deadline, now.addingTimeInterval(0.1)))
        }
        return value
    }

    deinit {
        // Nothing to release.
    }
}
