import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// A number that threads count up.
///
/// Unchecked: the number is guarded by `lock`.
internal final class CovNetCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// How often `add` was called.
    internal var value: Int { lock.withLock { count } }

    /// Nothing counted yet.
    internal init() {
        // Nothing is counted yet.
    }

    /// Counts one more.
    internal func add() {
        lock.withLock { count += 1 }
    }

    deinit {
        // Nothing to release.
    }
}
