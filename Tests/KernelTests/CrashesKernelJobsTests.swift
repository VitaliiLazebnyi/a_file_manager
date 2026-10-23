import AFMKernel
import TestSupport
import Testing

/// The completion of a job that ends after its kernel has gone (a window closed, a test ended) is
/// not called: the plugins that would hear of it went with the kernel.
@MainActor
internal struct CrashesKernelJobsTests {
    /// A job service that keeps the completions of the jobs it ran.
    private final class HeldJobs: JobService {
        /// The completions, with their results.
        var held: [() -> Void] = []
        /// Whatever the test says.
        var isBusy = false

        /// The work done at once; the jobs run here are immediate.
        private let immediate = ImmediateJobService()

        /// Does `work` at once and keeps `completion` with its result.
        func run<Result: Sendable>(
            title: String,
            work: @escaping @Sendable (any JobMonitor) -> Result,
            completion: @escaping @MainActor (Result) -> Void
        ) {
            immediate.run(title: title, work: work) { [self] result in held.append { completion(result) } }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A shell whose jobs do their work at once and keep their completions until asked to deliver them.
    private final class HoldingShell: ShellServices {
        let panelSet: FakePanelSet
        let held = HeldJobs()

        var panels: any PanelSet { panelSet }
        var jobs: any JobService { held }

        init() {
            let memory = MemoryFileSystem()
            let fileSystems = FileSystemRegistry()
            fileSystems.register(memory)
            panelSet = FakePanelSet(
                left: FakePanel(showing: memory.url("/"), fileSystems: fileSystems),
                right: FakePanel(showing: memory.url("/"), fileSystems: fileSystems)
            )
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A job's completion comes while its kernel is there, and not once the kernel has gone.
    @Test
    internal func aJobThatEndsAfterItsKernelHasGoneIsNotDelivered() {
        let shell = HoldingShell()
        var delivered: [Int] = []
        weak var gone: Kernel?
        do {
            let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
            kernel.attach(shell)
            gone = kernel
            shell.held.isBusy = true
            #expect(kernel.jobs.isBusy)
            kernel.jobs.run(title: "First", work: { _ in 1 }, completion: { delivered.append($0) })
            kernel.jobs.run(title: "Second", work: { _ in 2 }, completion: { delivered.append($0) })
            shell.held.held.removeFirst()()
        }
        #expect(gone == nil && delivered == [1])
        shell.held.held.removeFirst()()
        #expect(delivered == [1] && shell.held.held.isEmpty)
    }
}
