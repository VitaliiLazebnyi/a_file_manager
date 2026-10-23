import Foundation

/// A clock for the delayed writes that the test turns by hand.
///
/// Unchecked: what is due is guarded by `lock`.
internal final class HandClock: @unchecked Sendable {
    /// One piece of work the archives asked to run later.
    internal struct Due {
        /// The seconds it was to wait.
        internal let delay: TimeInterval
        /// The priority it was to run at.
        internal let priority: QualityOfService
        /// The work; the test runs it when it likes.
        internal let work: @Sendable () -> Void
    }

    /// Guards `waiting`.
    private let lock = NSLock()
    /// What was scheduled and not taken yet, in order.
    private var waiting: [Due] = []

    /// Notes `work` as due after `delay` at `priority`; nothing runs until the test runs it.
    internal func schedule(
        _ delay: TimeInterval,
        _ priority: QualityOfService,
        _ work: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        waiting.append(Due(delay: delay, priority: priority, work: work))
        lock.unlock()
    }

    /// What was scheduled since the last call, in the order it was.
    internal func take() -> [Due] {
        lock.lock()
        defer { lock.unlock() }
        let taken = waiting
        waiting = []
        return taken
    }

    deinit {
        // Nothing to release.
    }
}
