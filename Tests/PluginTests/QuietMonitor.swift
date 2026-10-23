import AFMKernel
import Foundation

@testable import ArchivesPlugin

/// A monitor for packing and unpacking outside a job service.
///
/// Unchecked: the reports are guarded by `lock`.
internal final class QuietMonitor: JobMonitor, @unchecked Sendable {
    /// The flag a test sets to cancel the work this monitor watches.
    internal let cancellation = CancellationFlag()
    private let lock = NSLock()
    private var all: [JobProgress] = []

    /// Every progress report so far, oldest first; safe from any thread.
    internal var reports: [JobProgress] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    /// Keeps the report; called from the thread that does the work.
    internal func report(_ progress: JobProgress) {
        lock.lock()
        all.append(progress)
        lock.unlock()
    }

    /// Asks the question on the main thread, waiting there for the answer when called from another thread.
    internal func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
        Thread.isMainThread ? MainActor.assumeIsolated(question) : DispatchQueue.main.sync { question() }
    }

    deinit {
        // Nothing to release.
    }
}
