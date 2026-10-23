import Foundation

/// The text on the clipboard for `[X]`, read when a mask asks for it and not before, and kept
/// until the clipboard changes.
///
/// A mask does not wait for it on its own thread: a queue of the session asks for it (`read`, which
/// reads on the main thread) and the mask waits at most `Snapshot.patience` (a program that
/// provides its text only when asked can take as long as it likes). Main thread; its snapshots are
/// safe to use from several threads.
@MainActor
internal final class ClipboardSource {
    /// One reading of the clipboard.
    ///
    /// Unchecked `Sendable`: the state is guarded by `condition`; `read` and `queue` do not change
    /// after `init`.
    internal final class Snapshot: @unchecked Sendable {
        /// The longest text taken: a name holds a line of it at the most.
        internal static let longest = 1 << 16
        /// How long a mask waits for a program that does not answer.
        internal static let patience: TimeInterval = 2
        /// For this long after giving up, nobody waits again.
        internal static let grace: TimeInterval = 10

        private let condition = NSCondition()
        private var text: String?
        private var isRead = false
        private var isRequested = false
        private var gaveUpAt: Date?
        private let read: @Sendable () -> String?
        private let queue: DispatchQueue

        /// A reading that `read` does on `queue` when the value is first asked for.
        internal init(read: @escaping @Sendable () -> String?, queue: DispatchQueue) {
            self.read = read
            self.queue = queue
        }

        /// The text, or nil when there is none or the clipboard does not answer in time.
        internal func value() -> String? {
            condition.lock()
            if !isRequested {
                isRequested = true
                queue.async { [self] in
                    let found = read().map { String($0.prefix(Self.longest)) }
                    condition.lock()
                    (text, isRead) = (found, true)
                    condition.broadcast()
                    condition.unlock()
                }
            }
            defer { condition.unlock() }
            // A clipboard that was waited for in vain is not waited for again by every name of the list.
            if !isRead, let gaveUp = gaveUpAt, Date().timeIntervalSince(gaveUp) < Self.grace {
                return nil
            }
            let deadline = Date(timeIntervalSinceNow: Self.patience)
            while !isRead, condition.wait(until: deadline) {
                // Woken before the deadline: the text may be there now.
            }
            if !isRead {
                gaveUpAt = Date()
            }
            return isRead ? text : nil
        }

        deinit {
            // Nothing to release.
        }
    }

    private let read: @Sendable () -> String?
    private let changeCount: (@MainActor () -> Int)?
    private let queue = DispatchQueue(label: "multirename.clipboard", qos: .userInitiated)
    private var last: (count: Int, snapshot: Snapshot)?

    /// A source that reads the clipboard with `read`; without `changeCount` the clipboard is read again
    /// for every preview.
    internal init(read: @escaping @Sendable () -> String?, changeCount: (@MainActor () -> Int)?) {
        self.read = read
        self.changeCount = changeCount
    }

    /// The clipboard as it is now.
    ///
    /// Cheap: nothing is read until the snapshot is asked for its value, and a clipboard that has
    /// not changed since the last call gives the same snapshot.
    internal func snapshot() -> Snapshot {
        guard let changeCount else {
            return Snapshot(read: read, queue: queue)
        }
        let count = changeCount()
        if let last, last.count == count {
            return last.snapshot
        }
        let fresh = Snapshot(read: read, queue: queue)
        last = (count, fresh)
        return fresh
    }

    deinit {
        // Nothing to release.
    }
}
