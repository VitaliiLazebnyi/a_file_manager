import AFMKernel
import Foundation
import TestSupport

/// Runs each job at once on the calling thread, as `ImmediateJobService` does, but as if the user
/// had pressed Cancel before it began; it is also the shell of a kernel, with fake panels.
///
/// Main thread only.
internal final class CoverageNetworkCancelledJobs: JobService, ShellServices {
    /// The monitor of a job that was cancelled at once.
    ///
    /// Unchecked: nothing in it changes.
    private final class Monitor: JobMonitor, @unchecked Sendable {
        let cancellation = CancellationFlag()

        init() {
            cancellation.cancel()
        }

        func report(_: JobProgress) {
            // Nobody watches.
        }

        func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
            MainActor.assumeIsolated(question)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The panels.
    internal let panelSet: FakePanelSet
    /// Never true between calls.
    internal private(set) var isBusy = false

    /// The panels, for the kernel.
    internal var panels: any PanelSet { panelSet }
    /// This service, for the kernel.
    internal var jobs: any JobService { self }

    /// A shell whose panels show `left` and `right`, read through `fileSystems`.
    internal init(left: URL, right: URL, fileSystems: FileSystemRegistry) {
        panelSet = FakePanelSet(
            left: FakePanel(showing: left, fileSystems: fileSystems),
            right: FakePanel(showing: right, fileSystems: fileSystems)
        )
    }

    /// Runs `work` with a cancelled monitor, then `completion`, before returning.
    @preconcurrency
    internal func run<Result: Sendable>(
        title _: String,
        work: @Sendable (any JobMonitor) -> Result,
        completion: @MainActor (Result) -> Void
    ) {
        isBusy = true
        let result = work(Monitor())
        isBusy = false
        completion(result)
    }

    deinit {
        // Nothing to release.
    }
}
