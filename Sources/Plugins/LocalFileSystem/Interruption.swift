import Foundation

/// Lets another thread end a system call this thread is blocked in (an `open`, `read` or
/// `write` on a share that has stopped answering), by a signal that does nothing except
/// interrupt the call.
///
/// Used by the local readers and writers for `interrupt()`, and by the opening calls for the
/// `CancellationFlag` they are given.
///
/// The signal is only ever sent to a thread that has announced, with `begin()`, that it is
/// inside one call; a signal that comes a moment too early is sent again until the call is
/// over. **Thread-safe**; `interrupt()` returns at once. All state is guarded by `lock`.
internal final class Interruption: @unchecked Sendable {
    /// Runs `work` once `delay` seconds have passed, on another thread.
    internal typealias Schedule = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    /// A handler that does nothing, installed without `SA_RESTART`: the call it interrupts
    /// returns `EINTR` instead of carrying on.
    ///
    /// (Installing a handler for a valid signal does not fail.).
    private static let installed: Void = {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            // Nothing: the call the signal arrives in returns `EINTR`, which is all it is for.
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGURG, &action, nil)
    }()

    private let lock = NSLock()
    private var thread: pthread_t?
    private var interrupted = false
    /// Where the signal is sent again: the local file system's clock.
    private let schedule: Schedule

    /// True once `interrupt()` was called; it stays true.
    internal var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    /// An interruption that sends its signal again on the local file system's clock.
    internal convenience init() {
        self.init { delay, work in LocalClock.queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// An interruption that sends its signal again where `schedule` says (tests count the times).
    internal init(schedule: @escaping Schedule) {
        self.schedule = schedule
    }

    /// The calling thread is about to make a call that may wait.
    ///
    /// False when `interrupt` was called already: the call is not to be made.
    internal func begin() -> Bool {
        Self.installed
        // Some threads (those of Swift's concurrency pool) have it blocked, and then it would not arrive.
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGURG)
        pthread_sigmask(SIG_UNBLOCK, &signals, nil)
        lock.lock()
        defer { lock.unlock() }
        if interrupted {
            return false
        }
        thread = pthread_self()
        return true
    }

    /// The call that `begin()` announced is over: no signal is sent to this thread any more.
    internal func end() {
        lock.lock()
        thread = nil
        lock.unlock()
    }

    /// Ends the call under way, if any, and every later one before it is begun; from any thread.
    internal func interrupt() {
        lock.lock()
        interrupted = true
        let target = thread
        if let target { pthread_kill(target, SIGURG) }
        lock.unlock()
        if target != nil { resend(attempt: 1) }
    }

    /// The call may not have been entered yet when the first signal arrived.
    private func resend(attempt: Int) {
        guard attempt <= 50 else {
            return
        }
        schedule(0.1) { [self] in
            lock.lock()
            let target = thread
            if let target { pthread_kill(target, SIGURG) }
            lock.unlock()
            if target != nil { resend(attempt: attempt + 1) }
        }
    }

    /// Runs `call` (one system call, returning a negative number and setting `errno` on
    /// failure), again after an `EINTR` that nobody asked for.
    ///
    /// Throws `userCancelled` once interrupted. Returns the result, or a negative number with
    /// `errno` set.
    internal func run(_ call: () -> Int) throws -> Int {
        var (result, code): (Int, Int32)
        repeat {
            guard begin() else { throw CocoaError(.userCancelled) }
            result = call()
            code = errno
            end()
            if result < 0, code == EINTR, isInterrupted { throw CocoaError(.userCancelled) }
        } while result < 0 && code == EINTR
        errno = code
        return result
    }

    deinit {
        // Nothing to release.
    }
}
