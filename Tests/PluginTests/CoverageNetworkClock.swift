import Foundation

/// A clock that stands still until the test moves it.
///
/// Unchecked: the time is guarded by `lock`.
internal final class CoverageNetworkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_700_000_000)

    /// The time it shows.
    internal var now: Date { lock.withLock { time } }

    /// A clock at a fixed moment.
    internal init() {
        // The moment is set above.
    }

    /// Moves the clock on.
    internal func advance(by seconds: TimeInterval) {
        lock.withLock { time += seconds }
    }

    deinit {
        // Nothing to release.
    }
}
