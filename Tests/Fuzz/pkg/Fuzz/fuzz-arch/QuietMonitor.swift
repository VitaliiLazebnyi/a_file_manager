import AFMKernel

/// A monitor for packing and unpacking outside a job: it reports nowhere and nothing cancels it.
internal final class QuietMonitor: JobMonitor, Sendable {
    /// Never set: nothing cancels the fuzzer's work.
    internal let cancellation = CancellationFlag()

    /// Drops the report.
    internal func report(_: JobProgress) {
        // Nobody watches the progress.
    }

    /// Answers at once.
    ///
    /// The fuzzer packs and unpacks on the main thread, so the question runs there.
    internal func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
        MainActor.assumeIsolated(question)
    }

    deinit {
        // Nothing to release.
    }
}
