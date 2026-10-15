import Foundation

/// A clock for the archives' timers that the test turns by hand: what is scheduled waits here
/// until the test runs it.
///
/// Unchecked: what is due is guarded by `lock`.
internal final class CoverageArchivesClock: @unchecked Sendable {
    /// One piece of work that was scheduled.
    internal struct Due {
        /// After how long it was to run.
        internal let delay: TimeInterval
        /// The work itself.
        internal let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var waiting: [Due] = []

    /// Notes `work` instead of running it; the shape of `ArchiveEnvironment.Scheduler`.
    internal func schedule(
        _ delay: TimeInterval,
        _ priority: QualityOfService,
        _ work: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        waiting.append(Due(delay: delay, work: work))
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

    /// Runs what was scheduled since the last call; returns how much that was.
    @discardableResult
    internal func runDue() -> Int {
        let due = take()
        due.forEach { $0.work() }
        return due.count
    }

    deinit {
        // Nothing to release.
    }
}
