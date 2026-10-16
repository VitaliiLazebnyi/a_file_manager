import Foundation

/// Set once the watcher is stopped or has gone: reports still under way are dropped.
/// All state is guarded by `lock`.
internal final class FSEvGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    /// Whether the watcher was stopped.
    internal var isStopped: Bool {
        lock.withLock { stopped }
    }

    /// From now on, the watcher counts as stopped.
    internal func stop() {
        lock.withLock { stopped = true }
    }

    deinit {
        // Nothing to release.
    }
}
