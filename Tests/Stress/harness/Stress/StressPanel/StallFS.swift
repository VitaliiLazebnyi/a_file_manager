import AFMKernel
import Foundation
import TestSupport

/// A provider (scheme `stall`) in front of a `MemoryFileSystem` that stops answering on request.
///
/// Its questions about single files (`item(at:)`, `volume(of:)`, `totalSize`, `entries`) do not answer
/// while `isStalled` is set, like a share that has stopped talking. Listings stall through the
/// memory file system's own `stallsListings`.
///
/// A call that arrives ON THE MAIN THREAD while stalled is not held (the harness would hang):
/// it is recorded with its stack as "would have frozen the window", and answered.
///
/// Unchecked: every stored `var` is guarded by `gate`; `inner` is a `let` of a Sendable type.
internal final class StallFS: @unchecked Sendable {
    /// The memory file system that answers once the provider talks.
    internal let inner: MemoryFileSystem
    /// The URL scheme of the provider.
    internal let scheme = "stall"
    /// Guards the state below; blocked calls wait on it.
    private let gate = NSCondition()
    /// Whether calls are held.
    private var stalled = false
    /// Calls held now.
    private var blocked = 0
    /// The most calls held at once.
    private var mostBlocked = 0
    /// Calls held now, by method.
    private var blockedBy: [String: Int] = [:]
    /// Calls that arrived on the main thread while stalled, by method: how many, and the first stack.
    private var mainThreadCalls: [String: (count: Int, stack: [String])] = [:]
    /// Every call, by method.
    private var calls: [String: Int] = [:]

    /// Calls held now, by method, as `method=count` pairs.
    internal var blockedByMethod: String {
        gate.lock()
        defer { gate.unlock() }
        let held = blockedBy.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        return held.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }

    /// Whether calls are held; setting it to false lets the held calls go on.
    internal var isStalled: Bool {
        get {
            gate.lock()
            defer { gate.unlock() }
            return stalled
        }
        set {
            gate.lock()
            stalled = newValue
            gate.broadcast()
            gate.unlock()
            inner.stallsListings = newValue
        }
    }

    /// Calls held now.
    internal var blockedNow: Int {
        gate.lock()
        defer { gate.unlock() }
        return blocked
    }

    /// The most calls held at once so far.
    internal var mostBlockedAtOnce: Int {
        gate.lock()
        defer { gate.unlock() }
        return mostBlocked
    }

    /// A provider that answers, with an empty share that is not local.
    internal init() {
        inner = MemoryFileSystem(scheme: "stall")
        inner.isLocal = false
    }

    /// Lets every held call and listing go on.
    internal func release() {
        isStalled = false
        inner.releaseStalls()
    }

    /// Counts a call of `what` that is never held.
    internal func count(_ what: String) {
        gate.lock()
        calls[what, default: 0] += 1
        gate.unlock()
    }

    /// Counts a call of `what` and, while stalled, holds it until the stall ends or `cancellation` is set.
    internal func wait(_ what: String, cancellation: CancellationFlag?) {
        gate.lock()
        calls[what, default: 0] += 1
        guard stalled else {
            gate.unlock()
            return
        }
        if Thread.isMainThread {
            var entry = mainThreadCalls[what] ?? (0, Thread.callStackSymbols)
            entry.count += 1
            mainThreadCalls[what] = entry
            gate.unlock()
            return
        }
        gate.unlock()
        let waiting = cancellation?
            .onCancel { [gate] in
                gate.lock()
                gate.broadcast()
                gate.unlock()
            }
        defer { _ = waiting }
        gate.lock()
        blocked += 1
        blockedBy[what, default: 0] += 1
        mostBlocked = max(mostBlocked, blocked)
        while stalled, cancellation?.isCancelled != true {
            gate.wait()
        }
        blocked -= 1
        blockedBy[what, default: 0] -= 1
        gate.unlock()
    }

    /// `wait(_:cancellation:)` for a call that cannot be cancelled.
    internal func wait(_ what: String) {
        wait(what, cancellation: nil)
    }

    /// Every call by method, and the calls that arrived on the main thread while stalled.
    internal func snapshotCalls() -> (calls: [String: Int], main: [String: (count: Int, stack: [String])]) {
        gate.lock()
        defer { gate.unlock() }
        return (calls, mainThreadCalls)
    }

    deinit {
        // Nothing to release.
    }
}
