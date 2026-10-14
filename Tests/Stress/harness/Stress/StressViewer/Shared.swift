import Foundation

/// A value that a background thread hands to the main thread, behind a lock.
///
/// Unchecked: `stored` is only read and written with `lock` held.
internal final class Shared<Value: Sendable>: @unchecked Sendable {
    /// Guards `stored`.
    private let lock = NSLock()
    /// The value.
    private var stored: Value

    /// The value, read or written under the lock.
    internal var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    /// A shared `value`.
    internal init(_ value: Value) {
        stored = value
    }

    deinit {
        // Nothing to release.
    }
}
