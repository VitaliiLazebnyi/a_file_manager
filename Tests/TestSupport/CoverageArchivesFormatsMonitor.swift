public import AFMKernel
import Foundation

/// A job monitor for packing and unpacking outside a job service that lets a test act at the
/// moments the job looks at it: when it reports progress, and when it asks whether it is cancelled.
///
/// Unchecked: the hooks are guarded by `lock`; they are called on the job's thread.
public final class CoverageArchivesFormatsMonitor: JobMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private let flag = CancellationFlag()
    private var reportHook: (@Sendable (JobProgress) -> Void)?
    private var askedHook: (@Sendable () -> Void)?

    /// The flag of the job; asking for it runs the hook set with `whenAsked`.
    public var cancellation: CancellationFlag {
        lock.lock()
        let hook = askedHook
        lock.unlock()
        hook?()
        return flag
    }

    /// A monitor without hooks.
    public init() {
        // Nothing else to set up.
    }

    /// Runs `hook` with every report from now on.
    @preconcurrency
    public func whenReporting(_ hook: @escaping @Sendable (JobProgress) -> Void) {
        lock.lock()
        reportHook = hook
        lock.unlock()
    }

    /// Runs `hook` whenever the job asks for its cancellation flag, from now on.
    @preconcurrency
    public func whenAsked(_ hook: @escaping @Sendable () -> Void) {
        lock.lock()
        askedHook = hook
        lock.unlock()
    }

    /// Hands the report to the hook, if there is one.
    public func report(_ progress: JobProgress) {
        lock.lock()
        let hook = reportHook
        lock.unlock()
        hook?(progress)
    }

    /// Answers on the main thread, as a job service does.
    @preconcurrency
    public func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
        Thread.isMainThread ? MainActor.assumeIsolated(question) : DispatchQueue.main.sync { question() }
    }

    deinit {
        // Nothing to release.
    }
}
