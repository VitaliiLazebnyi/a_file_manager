import os

/// A count that several threads add to.
internal final class Counter: Sendable {
    /// The count, behind its lock.
    private let value = OSAllocatedUnfairLock(initialState: 0)

    /// The count now.
    internal var count: Int {
        value.withLock { $0 }
    }

    /// Adds `amount`.
    internal func add(_ amount: Int) {
        value.withLock { $0 += amount }
    }

    deinit {
        // Nothing to release.
    }
}
