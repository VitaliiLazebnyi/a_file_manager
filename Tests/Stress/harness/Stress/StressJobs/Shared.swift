import Foundation

/// A value that several threads read and write, one at a time.
///
/// Unchecked: `stored` is only read and written under `lock`.
internal final class Shared<Value: Sendable>: @unchecked Sendable {
    /// Guards `stored`.
    private let lock = NSLock()
    /// The value; read and written through `value` and `update`.
    private var stored: Value

    /// The value, read or written under the lock.
    internal var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// A box that holds `value` at first.
    internal init(_ value: Value) {
        stored = value
    }

    /// Changes the value in place, under the lock.
    internal func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }

    deinit {
        // Nothing to release.
    }
}
