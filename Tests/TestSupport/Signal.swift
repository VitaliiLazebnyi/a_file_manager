public import Foundation

/// Something set on one thread and waited for on another, without a clock in between.
///
/// The value is handed over whole: it is made on one thread and used on the other only after
/// the wait. Unchecked: the value is guarded by `condition`.
public final class Signal<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?

    /// Nothing set yet.
    public init() {
        // Nothing is set yet.
    }

    /// Sets the value (a later one replaces it) and wakes whoever waits, from any thread.
    public func set(_ value: Value) {
        condition.lock()
        self.value = value
        condition.broadcast()
        condition.unlock()
    }

    /// The value, as soon as it is set; nil only when nothing came within `seconds`: a hang, to
    /// be reported as a failure.
    public func wait(seconds: TimeInterval = Wait.ceiling) -> Value? {
        let end = Date(timeIntervalSinceNow: seconds)
        condition.lock()
        defer { condition.unlock() }
        while value == nil, condition.wait(until: end) {
            // Woken: look again.
        }
        return value
    }

    deinit {
        // Nothing to release.
    }
}
