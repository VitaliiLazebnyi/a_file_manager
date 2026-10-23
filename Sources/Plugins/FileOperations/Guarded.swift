import Foundation

/// A value behind a lock.
///
/// Unchecked `Sendable`: `value` is guarded by `lock`.
internal final class Guarded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    internal init(_ value: Value) { self.value = value }
    internal func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
