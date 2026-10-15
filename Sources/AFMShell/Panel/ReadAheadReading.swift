import AFMKernel
import Foundation

/// The one reading a `ReadAhead` has on its way: what it reads, who waits for it, and what
/// the reading thread tells about its progress.
///
/// Unchecked: the main thread's part is isolated to it, and what is shared with the
/// reading thread is guarded by `lock`.
internal final class ReadAheadReading: @unchecked Sendable {
    /// The folder that is read.
    internal let target: ReadAhead.Target
    /// Set to stop the reading.
    internal let cancellation = CancellationFlag()
    /// Who gets the result, on the main thread.
    @MainActor internal var waiting: [@MainActor (ReadAhead.Outcome) -> Void] = []
    /// How many panels wait for the result.
    @MainActor internal var waiters = 0
    /// When the reading was told to stop (in the system's uptime).
    @MainActor internal var cancelledAt: TimeInterval?

    // Shared with the reading thread, behind the lock.
    private let lock = NSLock()
    private var joined = false
    private var givenUp = false
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var thread: pthread_t?
    private var boost: pthread_override_t?

    /// A panel waits for the result: the reading is no longer the cursor's to cancel.
    internal var isJoined: Bool { lock.withLock { joined } }

    /// The folder turned out to be larger than the cache takes, and nobody waited for it.
    internal var wasGivenUp: Bool { lock.withLock { givenUp } }

    /// A reading of `target`, not started yet.
    internal init(target: ReadAhead.Target) {
        self.target = target
    }

    /// Reading thread, when it starts.
    internal func began() {
        lock.withLock {
            thread = pthread_self()
            lastProgress = ProcessInfo.processInfo.systemUptime
            if joined {
                raise()
            }
        }
    }

    /// Reading thread, when it is done.
    internal func finished() {
        lock.withLock {
            if let boost {
                pthread_override_qos_class_end_np(boost)
            }
            (boost, thread) = (nil, nil)
        }
    }

    /// Reading thread: `count` entries have arrived.
    ///
    /// Returns false when the reading is to be given up: it has more entries than `limit` (what
    /// will be remembered) and no panel waits for it.
    internal func progress(_ count: Int, limit: Int) -> Bool {
        lock.withLock {
            lastProgress = ProcessInfo.processInfo.systemUptime
            if count > limit, !joined {
                givenUp = true
            }
            return !givenUp
        }
    }

    /// Main thread: a panel takes the reading over.
    ///
    /// False when it was given up meanwhile. Somebody waits for it now, so it goes on at the user's
    /// priority.
    internal func join() -> Bool {
        lock.withLock {
            guard !givenUp else {
                return false
            }
            joined = true
            raise()
            return true
        }
    }

    /// Main thread: no panel waits any more.
    internal func unjoin() {
        lock.withLock { joined = false }
    }

    /// Whether nothing has arrived for `time`.
    internal func isSilent(for time: TimeInterval) -> Bool {
        lock.withLock { ProcessInfo.processInfo.systemUptime - lastProgress > time }
    }

    /// Raises the reading thread to the user's priority.
    ///
    /// Called with the lock held.
    private func raise() {
        if boost == nil, let thread {
            boost = pthread_override_qos_class_start_np(thread, QOS_CLASS_USER_INITIATED, 0)
        }
    }

    deinit {
        // Nothing to release: the priority is handed back when the reading ends.
    }
}
