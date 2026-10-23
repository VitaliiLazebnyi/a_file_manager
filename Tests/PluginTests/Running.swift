import Foundation
import TestSupport

/// Runs `body` on a thread of its own and hands back what it returned or threw, when it is over.
///
/// Unchecked: the result is guarded by `condition`.
internal final class Running<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Value, any Error>?

    /// Whether `body` has returned or thrown; asked from any thread without waiting.
    internal var isOver: Bool {
        condition.lock()
        defer { condition.unlock() }
        return result != nil
    }

    /// Starts `body` on a new thread at once.
    internal init(_ body: @escaping @Sendable () throws -> Value) {
        Thread.detachNewThread { [self] in
            let outcome = Result { try body() }
            condition.lock()
            result = outcome
            condition.broadcast()
            condition.unlock()
        }
    }

    /// What `body` returned or threw, waited for.
    ///
    /// Nil when it did not end for a very long time (`Wait.ceiling`): a hang, reported as a failure.
    internal func wait() -> Result<Value, any Error>? {
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        condition.lock()
        defer { condition.unlock() }
        while result == nil, condition.wait(until: end) {
            // Woken by the end of `body`, or by the end of the patience.
        }
        return result
    }

    /// Whether `body` ended by throwing the user-cancelled error, waited for as `wait()` does.
    internal func endsCancelled() -> Bool {
        guard case .failure(let error)? = wait() else {
            return false
        }
        return (error as? CocoaError)?.code == .userCancelled
    }

    deinit {
        // Nothing to release: the thread holds the object until `body` is over.
    }
}
