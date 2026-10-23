import Foundation

/// Where the reader of a member hands the streams it reads through to its owner's request to
/// stop, which may come at any time from another thread.
///
/// A stream that is kept for the next reader (see `OpenArchive.park`) is let go of at `release()`,
/// so that a request that comes later cannot end somebody else's read. All state is guarded by
/// `lock`.
internal final class InterruptSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var current: StreamInterrupt?

    /// True once the owner asked to stop.
    internal var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    /// The owner's request to stop: sets the streams' request that is in the slot now, and any put in later.
    internal func interrupt() {
        lock.lock()
        interrupted = true
        // Under the lock: `release()` either comes before and this misses the chain, or after.
        current?.set()
        lock.unlock()
    }

    /// Puts the request of the streams that are read now in the slot; set at once if the owner already asked.
    internal func use(_ control: StreamInterrupt?) {
        lock.lock()
        current = control
        if interrupted { control?.set() }
        lock.unlock()
    }

    /// Lets go of the streams' request: a later `interrupt()` no longer reaches it.
    internal func release() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
