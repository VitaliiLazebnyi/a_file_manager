import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import StressKit
import TestSupport

@testable import AFMShell

/// The program without a visible window: kernel, all standard plugins, shell.
@MainActor
internal final class Running {
    /// The kernel with the standard plugins loaded.
    internal let kernel: Kernel
    /// The shell with its main window, never shown.
    internal let shell: Shell
    /// Answers the questions the program asks the user.
    internal let interaction = ScriptedInteraction()

    /// The left panel.
    internal var left: PanelViewController { shell.panelCoordinator.leftPanel }
    /// The right panel.
    internal var right: PanelViewController { shell.panelCoordinator.rightPanel }
    /// The kernel's commands.
    internal var commands: CommandRegistry { kernel.commands }
    /// True when no panel is loading and no job runs.
    internal var isSettled: Bool { !shell.panelCoordinator.isLoading && !kernel.jobs.isBusy }

    /// Starts the program with the panels at `left` and `right` and `providers` registered.
    internal init(left: URL, right: URL, home: URL, providers: [any FileSystemProvider]) {
        let settings = MemorySettings()
        settings.set(Self.state(left), forKey: "left.tabs")
        settings.set(Self.state(right), forKey: "right.tabs")
        kernel = Kernel(productName: StandardPlugins.productName, settings: settings, ui: interaction)
        for provider in providers {
            kernel.fileSystems.register(provider)
        }
        kernel.load(StandardPlugins.make(pasteboard: .withUniqueName(), launchesApplications: false))
        shell = Shell(kernel: kernel, home: home)
        shell.mainWindow.window?.setContentSize(NSSize(width: 1_500, height: 900))
        layOut()
    }

    /// The remembered tabs of a panel with one tab at `folder`.
    private static func state(_ folder: URL) -> PanelTabs.State {
        PanelTabs.State(tabs: [.init(location: folder)], active: 0)
    }

    /// Lays the window's views out.
    internal func layOut() {
        shell.mainWindow.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Runs the main run loop until the program settles; false after 120 s.
    internal func settle() -> Bool {
        pump(upTo: 120) { self.isSettled }
    }

    /// Has the list draw itself into a bitmap, as it would on screen.
    internal func draw(_ panel: PanelViewController) {
        let view: NSView = panel.showsGrid ? panel.gridView : panel.tableView
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else {
            return
        }
        view.cacheDisplay(in: view.visibleRect, to: bitmap)
    }

    /// What the validation tick and an opened menu ask: every bar, every command, every menu item.
    internal func validateEverything(menu: NSMenu) -> ValidationTimes {
        let started = now()
        shell.mainWindow.validateBars()
        let barsDone = now()
        for command in kernel.commands.all {
            _ = kernel.commands.isEnabled(command.id)
            _ = kernel.commands.isChecked(command.id)
        }
        let commandsDone = now()
        validateItems(of: menu)
        return ValidationTimes(
            bars: barsDone - started,
            commands: commandsDone - barsDone,
            menu: now() - commandsDone
        )
    }

    /// Validates every item of `menu` and of its submenus, as opening it would.
    internal func validateItems(of menu: NSMenu) {
        for item in menu.items {
            _ = shell.mainWindow.validateMenuItem(item)
            if let submenu = item.submenu {
                validateItems(of: submenu)
            }
        }
    }

    /// Shuts the shell and the kernel down.
    internal func stop() {
        shell.shutDown()
        kernel.shutdown()
    }

    deinit {
        // Nothing to release.
    }
}
