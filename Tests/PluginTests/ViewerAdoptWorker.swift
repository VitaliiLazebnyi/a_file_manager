import Darwin
import Foundation
import TestSupport

/// A function that runs on a thread of its own, for work that is meant to block: it says when
/// the thread waits (in a read that never answers), so a test sets the flag then and not "after a
/// moment".
///
/// Unchecked: `port` is written by the worker before it signals `started`, and read after that;
/// `thread` is set in `init`.
internal final class ViewerAdoptWorker: @unchecked Sendable {
    private var port: mach_port_t = 0
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    /// Whether the thread is waiting on something now (a condition, a lock).
    internal var isWaiting: Bool {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), words, &count)
            }
        }
        return result == KERN_SUCCESS && info.run_state == TH_STATE_WAITING
    }

    /// Makes the thread that will run `body`; `start()` starts it.
    internal init(_ body: @escaping @Sendable () -> Void) {
        thread = Thread { [self] in
            port = mach_thread_self()
            started.signal()
            body()
            finished.signal()
        }
    }

    /// Starts the thread and returns once it runs (or the tests' ceiling has passed).
    internal func start() {
        thread?.start()
        _ = started.wait(timeout: .now() + Wait.ceiling)
    }

    /// Polls until the thread waits; false when it did not within the tests' ceiling.
    internal func waitUntilWaiting() -> Bool {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !isWaiting, Date() < deadline { usleep(2_000) }
        return isWaiting
    }

    /// True when the body returned within the tests' ceiling.
    internal func waitUntilFinished() -> Bool {
        finished.wait(timeout: .now() + Wait.ceiling) == .success
    }

    deinit {
        // Nothing to release.
    }
}
