import AFMKernel
import Foundation

/// Where the calls of a `MemoryFileSystem` wait while it plays a server that has stopped
/// answering, and the count of who waits, which tests wait for (a condition, not a length of time).
///
/// Unchecked: every value is guarded by `condition`.
internal final class MemoryStalls: @unchecked Sendable {
    private let condition = NSCondition()
    /// Set by `release()`: from then on nothing stalls.
    private var isReleased = false
    /// What waits in a stalled listing right now, by path.
    private var listings: [String: Int] = [:]
    private var changes = 0
    private var transfers = 0

    /// How many changing calls wait right now.
    internal var waitingChanges: Int { locked { changes } }

    /// How many reads and writes wait right now.
    internal var waitingTransfers: Int { locked { transfers } }

    /// How many listings of `path` wait right now.
    internal func waitingListings(of path: String) -> Int { locked { listings[path] ?? 0 } }

    /// Lets everything that waits go on, and nothing stall from now on.
    internal func release() {
        locked {
            isReleased = true
            condition.broadcast()
        }
    }

    /// Wakes whoever waits so that they look at their flags again; for cancellation handlers.
    internal func wake() {
        locked { condition.broadcast() }
    }

    /// Wakes the waiters whenever `cancellation` is set, for as long as the result is kept.
    internal func waking(on cancellation: CancellationFlag) -> AnyObject {
        cancellation.onCancel { [weak self] in self?.wake() }
    }

    /// A listing of `path` waits here: while `stalling`, until released, otherwise until `end`; either way no longer
    /// than until `cancellation` is set.
    ///
    /// False when it was set.
    internal func pause(_ path: String, stalling: Bool, until end: Date, cancellation: CancellationFlag) -> Bool {
        locked {
            if stalling {
                listings[path, default: 0] += 1
            }
            while !cancellation.isCancelled, stalling ? !isReleased : end.timeIntervalSinceNow > 0 {
                if stalling {
                    condition.wait()
                } else {
                    condition.wait(until: end)
                }
            }
            if stalling {
                listings[path, default: 1] -= 1
            }
            return !cancellation.isCancelled
        }
    }

    /// A changing call waits here until released or until `cancellation` is set.
    internal func holdChange(cancellation: CancellationFlag) {
        locked {
            changes += 1
            while !cancellation.isCancelled, !isReleased {
                condition.wait()
            }
            changes -= 1
        }
    }

    /// A read or a write waits here, while `stalling`, until released or until `isInterrupted`
    /// (asked with the lock held) holds.
    internal func holdTransfer(stalling: Bool, isInterrupted: () -> Bool) {
        locked {
            guard stalling, !isInterrupted(), !isReleased else {
                return
            }
            transfers += 1
            while !isInterrupted(), !isReleased {
                condition.wait()
            }
            transfers -= 1
        }
    }

    /// Runs `body` with the lock held and returns what it returns.
    ///
    /// For state that the waiters' conditions read, such as the `isInterrupted` of `holdTransfer`.
    /// With `waking`, the waiters look again afterwards.
    internal func withLock<Value>(waking: Bool, _ body: () -> Value) -> Value {
        locked {
            defer {
                if waking {
                    condition.broadcast()
                }
            }
            return body()
        }
    }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }

    deinit {
        // Nothing to release.
    }
}
