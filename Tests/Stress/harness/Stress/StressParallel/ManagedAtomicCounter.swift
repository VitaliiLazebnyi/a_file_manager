internal import TestSupport

/// A count that any thread may add to.
internal final class ManagedAtomicCounter: Sendable {
    /// The count.
    private let value = Shared(0)

    /// The count now.
    internal var count: Int {
        value.value
    }

    /// Whether nothing was added.
    internal var isZero: Bool {
        value.value == 0
    }

    /// Adds one.
    internal func add() {
        value.modify { $0 += 1 }
    }

    deinit {
        // Nothing to release.
    }
}
