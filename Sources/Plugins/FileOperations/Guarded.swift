import Foundation

/// A value behind a lock.
///
/// Unchecked `Sendable`: `value` is guarded by `lock`.
internal final class Guarded<Value: Sendable>: @unchecked Sendable {
    /// Guards `value`.
    private let lock = NSLock()
    /// The value; used under `lock` only.
    private var value: Value

    /// The value `value` behind a lock of its own.
    internal init(_ value: Value) { self.value = value }

    /// Runs `body` with the value, which it may change, under the lock; returns what `body` returns.
    internal func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    deinit {
        // Nothing to release.
    }
}
