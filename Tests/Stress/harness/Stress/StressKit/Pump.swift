internal import CoreFoundation

// Running the main run loop while a harness waits: timers, sources and the main dispatch queue
// keep going, as in the program. Main thread only.

/// Runs the main run loop until `condition` holds; false when `seconds` pass first.
@preconcurrency
@MainActor
@discardableResult
public func pump(upTo seconds: Double = 60, until condition: () -> Bool) -> Bool {
    let deadline = now() + seconds
    while !condition() {
        if now() > deadline {
            return false
        }
        CFRunLoopRunInMode(.defaultMode, 0.002, true)
    }
    return true
}

/// Runs the main run loop for `seconds`.
@preconcurrency
@MainActor
public func pump(for seconds: Double) {
    let deadline = now() + seconds
    while now() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.002, true)
    }
}

/// Runs the main run loop until the process has at most `limit` threads or `seconds` pass;
/// returns the number of threads then.
@preconcurrency
@MainActor
@discardableResult
public func waitForThreads(atMost limit: Int, upTo seconds: Double) -> Int {
    let deadline = now() + seconds
    while threadCount() > limit, now() < deadline {
        pump(for: 0.05)
    }
    return threadCount()
}
