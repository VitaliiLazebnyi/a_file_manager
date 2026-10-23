import AFMContracts
import AFMKernel
import Foundation
import TestSupport

/// A kernel with fake panels, like `TestBench`, with the user interface and the job service
/// a test brings.
internal final class P2Bench: ShellServices {
    /// The kernel the plugins were loaded into.
    internal let kernel: Kernel
    /// The two fake panels.
    internal let panelSet: FakePanelSet
    /// The job service the test brought.
    internal let jobs: any JobService

    /// The two fake panels, as the kernel sees them.
    internal var panels: any PanelSet { panelSet }
    /// The left panel.
    internal var left: FakePanel { panelSet.leftPanel }
    /// The right panel.
    internal var right: FakePanel { panelSet.rightPanel }
    /// The kernel's commands.
    internal var commands: CommandRegistry { kernel.commands }

    /// A kernel with `plugins` and `fileSystems` loaded, its panels showing `left` and `right`, asking
    /// `interaction`, running jobs with `jobs` and keeping settings in `settings`.
    internal init(
        plugins: [any Plugin],
        fileSystems: [any FileSystemProvider],
        left: URL,
        right: URL,
        interaction: any UserInteraction,
        jobs: any JobService,
        settings: any SettingsStore
    ) {
        kernel = Kernel(productName: "Test", settings: settings, interaction: interaction)
        fileSystems.forEach(kernel.fileSystems.register)
        kernel.load(plugins)
        panelSet = FakePanelSet(
            left: FakePanel(showing: left, fileSystems: kernel.fileSystems),
            right: FakePanel(showing: right, fileSystems: kernel.fileSystems)
        )
        self.jobs = jobs
        kernel.attach(self)
    }

    deinit {
        // Nothing to release.
    }
}
