import Foundation

/// A number several threads add to.
///
/// All state is guarded by `lock`.
internal final class SharedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    /// The sum of everything added so far; any thread.
    internal var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    /// Adds `amount` to the sum; any thread.
    internal func add(_ amount: Int64) {
        lock.lock()
        total += amount
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
