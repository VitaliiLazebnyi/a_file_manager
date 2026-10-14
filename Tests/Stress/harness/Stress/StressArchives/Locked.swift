import Foundation

/// A value that several threads read and write.
///
/// Unchecked: `stored` is only touched while `lock` is held.
internal final class Locked<Value>: @unchecked Sendable {
    /// Guards `stored`.
    private let lock = NSLock()
    /// The value.
    private var stored: Value

    /// The value now.
    internal var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// A box that holds `value`.
    internal init(_ value: Value) {
        stored = value
    }

    /// Runs `change` on the value with the lock held and returns what it returns.
    internal func update<Result>(_ change: (inout Value) -> Result) -> Result {
        lock.withLock { change(&stored) }
    }

    deinit {
        // Nothing to release.
    }
}
