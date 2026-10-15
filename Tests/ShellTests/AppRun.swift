import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// A started program, and what the tests reach into.
@MainActor
internal final class AppRun {
    /// The program's kernel.
    internal let kernel: Kernel
    /// The window shell around it.
    internal let shell: Shell

    /// The left panel.
    internal var left: PanelViewController { shell.panelCoordinator.leftPanel }
    /// The right panel.
    internal var right: PanelViewController { shell.panelCoordinator.rightPanel }
    /// The kernel's commands.
    internal var commands: CommandRegistry { kernel.commands }
    /// The main window.
    internal var window: MainWindowController { shell.mainWindow }
    /// The command line of the main window.
    internal var line: CommandLineView { shell.mainWindow.commandLine }

    /// The program of `kernel`, shown by `shell`.
    internal init(kernel: Kernel, shell: Shell) {
        self.kernel = kernel
        self.shell = shell
    }

    /// The key press of `keyCode` with `flags`, as AppKit hands it to a view.
    internal static func keyEvent(
        _ keyCode: UInt16,
        _ characters: String,
        _ flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    /// Ends watching and reading, so a finished test leaves nothing running.
    internal func stop() {
        shell.shutDown()
        kernel.shutdown()
    }

    /// Waits until nothing is being read and no job is running.
    internal func settle() async {
        await AppWait.until { !self.shell.panelCoordinator.isLoading && !self.kernel.jobs.isBusy }
    }

    /// The names `panel` shows.
    internal func names(_ panel: PanelViewController) -> [String] {
        panel.model.items.map(\.name)
    }

    /// Puts the cursor of `panel` on the entry called `name`.
    internal func cursor(_ panel: PanelViewController, on name: String) {
        panel.model.row(ofName: name).map(panel.model.moveCursor(to:))
    }

    /// Presses the key `keyCode` with `flags` in the source panel; true when it was used.
    internal func press(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> Bool {
        try press(keyCode, flags, in: shell.panelCoordinator.sourcePanel)
    }

    /// Presses the key `keyCode` with `flags` in `panel`; true when it was used.
    internal func press(
        _ keyCode: UInt16,
        _ flags: NSEvent.ModifierFlags,
        in panel: PanelViewController
    ) throws -> Bool {
        panel.handleKey(try Self.keyEvent(keyCode, "", flags))
    }

    deinit {
        // Nothing to release: `stop` ends what runs.
    }
}
