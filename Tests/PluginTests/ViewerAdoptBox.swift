import Foundation

/// A guarded value, for results that come from threads.
///
/// Unchecked: the value is guarded by `lock`.
internal final class ViewerAdoptBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    /// The value now; reading and setting it are each one step under the lock.
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

    /// A box holding `value`.
    internal init(_ value: Value) { stored = value }

    /// Changes the value in one step under the lock, so that no other change comes in between.
    internal func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
