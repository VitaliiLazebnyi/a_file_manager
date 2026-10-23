import Foundation

/// What a test collects from other threads.
///
/// Unchecked: the state is guarded by `lock`.
internal final class Collected<Value>: @unchecked Sendable {
    /// Guards `values`.
    private let lock = NSLock()
    /// What was added, in order.
    private var values: [Value] = []

    /// Everything added so far, in order.
    internal var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    /// Adds `value`; any thread may call it.
    internal func add(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
