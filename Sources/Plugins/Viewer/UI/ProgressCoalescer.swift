import Foundation

/// Brings the progress of an index that is built on other threads to the main thread, at most one
/// at a time and not more often than every 50 ms.
///
/// The threads that build hold this object and not the view, so the view is never released by one
/// of them (it would be taken apart on that thread).
///
/// `scheduled` and `last` are guarded by `lock`; `handler` belongs to the main thread.
internal final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private var last = DispatchTime(uptimeNanoseconds: 0)
    /// Set and called on the main thread.
    internal var handler: (@MainActor () -> Void)?

    /// Called from any thread.
    internal func signal() {
        lock.lock()
        let schedule = !scheduled
        scheduled = true
        let wait = max(0, 0.05 - Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9)
        lock.unlock()
        guard schedule else {
            return
        }
        // (At most 50 ms: `wait` is what is left of them.)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            lock.lock()
            scheduled = false
            last = DispatchTime.now()
            lock.unlock()
            // The main queue runs its blocks on the main thread.
            MainActor.assumeIsolated { handler?() }
        }
    }

    deinit {
        // Nothing to release.
    }
}
