public import AFMKernel
public import Foundation

/// A kernel with fake panels, like `TestBench`, whose jobs run as a `CoverageSmallJobs`
/// service says: cancelled before they start, or on a thread of their own.
///
/// Main thread only.
public final class CoverageSmallBench: ShellServices {
    /// The kernel, attached to this bench as its shell.
    public let kernel: Kernel
    /// The kernel's user interaction: script the answers here, read what was asked.
    public let interaction = ScriptedInteraction()
    /// The job service, as the fake it is.
    public let jobService: CoverageSmallJobs
    /// The two panels, as the fakes they are.
    public let panelSet: FakePanelSet

    /// The panels, for the kernel.
    public var panels: any PanelSet { panelSet }
    /// The job service, for the kernel.
    public var jobs: any JobService { jobService }
    /// The left panel.
    public var left: FakePanel { panelSet.leftPanel }
    /// The right panel.
    public var right: FakePanel { panelSet.rightPanel }
    /// The kernel's commands.
    public var commands: CommandRegistry { kernel.commands }

    /// Starts `plugins` and shows `left` and `right` in the panels; jobs run as `jobs` says.
    ///
    /// `fileSystems` are registered before the plugins start, like a file-system plugin would.
    public init(
        _ jobs: CoverageSmallJobs.Mode,
        plugins: [any Plugin],
        fileSystems: [any FileSystemProvider],
        left: URL,
        right: URL,
        settings: any SettingsStore = MemorySettings()
    ) {
        jobService = CoverageSmallJobs(jobs)
        kernel = Kernel(productName: "Test", settings: settings, interaction: interaction)
        fileSystems.forEach(kernel.fileSystems.register)
        kernel.load(plugins)
        panelSet = FakePanelSet(
            left: FakePanel(showing: left, fileSystems: kernel.fileSystems),
            right: FakePanel(showing: right, fileSystems: kernel.fileSystems)
        )
        kernel.attach(self)
    }

    deinit {
        // Nothing to release.
    }
}
