internal import Darwin
internal import Foundation
internal import StressKit
internal import TestSupport

/// Highest thread count seen while it runs.
internal final class ThreadPeak: Sendable {
    /// The highest count so far.
    private let peak = Shared(0)
    /// Whether the counting thread goes on.
    private let running = Shared(true)

    /// Starts counting on a thread of its own, every 5 ms.
    internal init() {
        let thread = Thread { [self] in
            while running.value {
                let count = threadCount()
                peak.modify { $0 = max($0, count) }
                usleep(5_000)
            }
        }
        thread.start()
    }

    /// Stops counting; returns the highest count seen.
    internal func stop() -> Int {
        running.value = false
        return peak.value
    }

    deinit {
        // Nothing to release.
    }
}
