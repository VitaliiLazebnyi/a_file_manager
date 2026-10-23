import AFMKernel
import Foundation

/// The lock that lets one write of an archive run at a time.
///
/// A write may take minutes and runs with low priority when the delay started it; a thread of the
/// user's own work that has to wait for it (a commit, a quit) lends it its priority for as long as
/// it waits, so the wait is not longer than the write itself needs.
///
/// A long write (anything but the small write of a rename, see `OpenArchive.move`) says so
/// when it takes the gate, in the same step: a rename sees it at once and does not wait
/// behind it, neither when it comes while such a write runs nor when one takes the gate
/// while the rename waits for another rename.
///
/// Unchecked: `holder` and `holdsLong` are guarded by `condition`.
internal final class FlushGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var holder: pthread_t?
    private var holdsLong = false

    private static func end(_ lent: pthread_override_t?) {
        if let lent {
            pthread_override_qos_class_end_np(lent)
        }
    }

    /// Waits for the gate; `long` for anything but the small write of a rename.
    ///
    /// With a `cancellation`, no longer than until it is set.
    internal func lock(long: Bool, cancellation: CancellationFlag?) throws {
        condition.lock()
        defer { condition.unlock() }
        let lent = lend()
        defer { Self.end(lent) }
        while holder != nil {
            guard let cancellation else {
                condition.wait()
                continue
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            if holder != nil, cancellation.isCancelled {
                throw ArchiveError.cancelled
            }
        }
        take(long: long)
    }

    /// Waits no longer than until `deadline`; `long` as for `lock(long:cancellation:)`.
    internal func lock(long: Bool, before deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let lent = lend()
        defer { Self.end(lent) }
        while holder != nil {
            if !condition.wait(until: deadline), holder != nil {
                return false
            }
        }
        take(long: long)
        return true
    }

    /// Waits for the gate while a short write holds it; false, without the gate, as soon as a
    /// long write holds it.
    internal func lockUnlessLong() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let lent = lend()
        defer { Self.end(lent) }
        while holder != nil {
            guard !holdsLong else {
                return false
            }
            condition.wait()
        }
        take(long: false)
        return true
    }

    /// Lets the next waiter take the gate.
    internal func unlock() {
        condition.lock()
        holder = nil
        holdsLong = false
        condition.broadcast()
        condition.unlock()
    }

    /// Takes the free gate.
    ///
    /// Called with `condition` held.
    private func take(long: Bool) {
        holder = pthread_self()
        holdsLong = long
    }

    /// The thread that holds the gate runs at this thread's priority until the returned mark
    /// is ended.
    ///
    /// Nil when there is nothing to lend. Called with `condition` held.
    private func lend() -> pthread_override_t? {
        let mine = qos_class_self()
        guard let holder, mine.rawValue > QOS_CLASS_UTILITY.rawValue else {
            return nil
        }
        // The holder cannot end before it has taken `condition` to step back, so it is alive here.
        return pthread_override_qos_class_start_np(holder, mine, 0)
    }

    deinit {
        // Nothing to release.
    }
}
