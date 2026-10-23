import AFMKernel
import Foundation
import TestSupport

/// A call made on a thread of its own, so that one which does not come back fails the test
/// instead of hanging it.
///
/// (Threads rather than `DispatchQueue.global()`, which stalls for seconds while the whole suite
/// runs.).
///
/// Unchecked: the lock guards `error` and `finished`.
internal final class AdoptOutcome: @unchecked Sendable {
    /// Guards `error` and `finished`.
    private let lock = NSLock()
    /// Signalled once when the call has ended.
    private let done = DispatchSemaphore(value: 0)
    /// What the call threw, if anything.
    private var error: (any Error)?
    /// True once the call has ended.
    private var finished = false

    /// What the call threw; nil while it runs and when it succeeded.
    internal var thrown: (any Error)? { lock.withLock { error } }

    /// True when the call has ended with an error.
    internal var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished && error != nil
    }

    /// Starts the call on a thread of its own.
    internal init(_ work: @escaping @Sendable () throws -> Void) {
        Thread { [self] in
            do { try work() } catch {
                lock.lock()
                self.error = error
                lock.unlock()
            }
            lock.lock()
            finished = true
            lock.unlock()
            done.signal()
        }
        .start()
    }

    /// True when the call ended within the longest wait of the tests (`Wait.ceiling`).
    ///
    /// The wait is long on purpose: these tests run beside many others, and what they show is
    /// that a call ends at all where the fault would be a wait of ten minutes or for ever, not how
    /// fast it ends.
    internal func ended() -> Bool {
        ended(within: Wait.ceiling)
    }

    /// True when the call ended within `seconds`.
    internal func ended(within seconds: TimeInterval) -> Bool {
        done.wait(timeout: .now() + seconds) == .success
    }

    deinit {
        // Nothing to release: the thread keeps what it needs.
    }
}

/// Waits until the condition holds, for the longest wait of the tests at most, and returns whether it holds.
internal func adoptWait(until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(Wait.ceiling)
    while !condition(), Date() < end {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// Sets the flag from a thread of its own after 0.3 seconds.
internal func adoptCancel(_ flag: CancellationFlag) {
    adoptCancel(flag, after: 0.3)
}

/// Sets the flag from a thread of its own after a moment.
internal func adoptCancel(_ flag: CancellationFlag, after delay: TimeInterval) {
    Thread {
        Thread.sleep(forTimeInterval: delay)
        flag.cancel()
    }
    .start()
}
