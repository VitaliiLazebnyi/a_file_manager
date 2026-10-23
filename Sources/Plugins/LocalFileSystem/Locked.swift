import Foundation

/// A value that several threads share, behind a lock.
///
/// All state is guarded by `lock`.
internal final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    /// Starts with `value`.
    internal init(_ value: Value) { self.value = value }

    /// Runs `body` on the value with the lock held, and returns what it returns; from any thread.
    @discardableResult
    internal func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    deinit {
        // Nothing to release.
    }
}
