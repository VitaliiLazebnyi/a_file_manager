import Foundation

/// The children that are running, so that a watch lives as long as its child and a waiting
/// chain can be stopped.
///
/// Used from the thread that starts a child, from the system's queue that reports its end, and from
/// the main thread. All state is guarded by `lock`.
internal final class ChildTable: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [pid_t: (watch: ChildProcess.Watch, waitedFor: Bool)] = [:]

    /// Calls `handler` once, on a queue of the system, when the child has ended; also when
    /// it has ended already.
    internal func watch(_ pid: pid_t, waitedFor: Bool, handler: @escaping @Sendable (ChildProcess.Ending) -> Void) {
        let watch = ChildProcess.Watch(pid: pid, calls: .system) { [weak self] ending in
            self?.remove(pid)
            handler(ending)
        }
        lock.lock()
        children[pid] = (watch, waitedFor)
        lock.unlock()
        watch.start()
    }

    private func remove(_ pid: pid_t) {
        lock.lock()
        children[pid] = nil
        lock.unlock()
    }

    /// Asks the children a chain waits for to end.
    internal func terminateWaitedFor() {
        lock.lock()
        let waited = children.filter(\.value.waitedFor).map(\.key)
        lock.unlock()
        for pid in waited {
            _ = kill(pid, SIGTERM)
        }
    }

    deinit {
        // Nothing to release.
    }
}
