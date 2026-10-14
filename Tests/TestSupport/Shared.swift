import Foundation

/// A value the test and the code under test share across threads.
///
/// Unchecked: the value is guarded by `lock`.
public final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    /// The value as it is now; reading and writing each take the lock, from any thread.
    public var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Starts with `value`.
    public init(_ value: Value) { stored = value }

    /// Changes the value in one step: `shared.modify { $0 += 1 }` loses no update to another
    /// thread, as `shared.value += 1` (a read, then a write) can.
    public func modify(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }

    deinit {
        // Nothing to release.
    }
}
