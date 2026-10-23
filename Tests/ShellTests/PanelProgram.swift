import AFMKernel
import AppKit
import StandardPlugins
import TestSupport

@testable import AFMShell

/// The real kernel, plugins and window shell, started without showing anything, for the tests of
/// the panels: a sandbox folder on the disk (`A` with two files and a folder, `B` with one file,
/// `home`), a memory file system, scripted answers to every question, settings in memory that
/// start the left panel in `A` and the right one in `B`, and a pasteboard of the test's own.
@MainActor
internal final class PanelProgram {
    /// A started program, and what the tests reach into.
    @MainActor
    internal final class Running {
        /// The kernel.
        internal let kernel: Kernel
        /// The window shell.
        internal let shell: Shell

        /// The left panel.
        internal var left: PanelViewController { shell.panelCoordinator.leftPanel }
        /// The right panel.
        internal var right: PanelViewController { shell.panelCoordinator.rightPanel }
        /// The kernel's commands.
        internal var commands: CommandRegistry { kernel.commands }
        /// How many times a command was turned away (the program beeps then; the tests count).
        internal private(set) var rejections = 0

        /// The program of `kernel` and `shell`.
        internal init(kernel: Kernel, shell: Shell) {
            self.kernel = kernel
            self.shell = shell
            kernel.commands.onRejected = { [weak self] in self?.rejections += 1 }
        }

        /// Ends watching and reading, so a finished test leaves nothing running.
        internal func stop() {
            shell.shutDown()
            kernel.shutdown()
            shell.mainWindow.window?.close()
        }

        /// The names of the entries a panel shows, in their order.
        internal func names(_ panel: PanelViewController) -> [String] {
            panel.model.items.map(\.name)
        }

        /// Puts a panel's cursor on the entry `name`.
        internal func cursor(_ panel: PanelViewController, on name: String) {
            panel.model.row(ofName: name).map(panel.model.moveCursor(to:))
        }

        /// Gives every view the size it has in the window.
        internal func layOut() {
            shell.mainWindow.window?.contentView?.layoutSubtreeIfNeeded()
            left.gridView.layOut()
            right.gridView.layOut()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The sandbox folder.
    internal let box: Sandbox
    /// A memory file system, registered before the plugins start.
    internal let memory = MemoryFileSystem()
    /// The answers to the program's questions, and what it asked.
    internal let interaction = ScriptedInteraction()
    /// The settings.
    internal let settings = MemorySettings()
    /// The pasteboard the program uses.
    internal let scratch = ScratchPasteboard()

    /// The plugins of the whole program, launching nothing.
    internal var standardPlugins: [any Plugin] {
        StandardPlugins.make(pasteboard: scratch.pasteboard, launchesApplications: false)
    }

    /// The folders, with `rightFile` (holding `contents`) as the one file in `B`.
    internal init(rightFile: String, contents: String) throws {
        _ = NSApplication.shared
        box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("A/two.txt", "2")
        try box.file("A/docs/in.txt", "inside")
        try box.file("B/" + rightFile, contents)
        try box.file("home/welcome.txt")
        settings.set(state(of: "A"), forKey: "left.tabs")
        settings.set(state(of: "B"), forKey: "right.tabs")
    }

    /// A key press, as AppKit would deliver it.
    internal static func key(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        guard
            let event = NSEvent.keyEvent(
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
        else {
            preconditionFailure("AppKit makes no key event")
        }
        return event
    }

    /// Starts the program with the standard plugins.
    internal func start() async -> Running {
        await start(plugins: standardPlugins, fileSystems: [])
    }

    /// Starts the program with `plugins`, `fileSystems` registered beside the memory file system,
    /// and waits until it is settled.
    internal func start(plugins: [any Plugin], fileSystems: [any FileSystemProvider]) async -> Running {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, interaction: interaction)
        kernel.fileSystems.register(memory)
        fileSystems.forEach(kernel.fileSystems.register)
        kernel.load(plugins)
        let running = Running(kernel: kernel, shell: Shell(kernel: kernel, home: box.url("home")))
        await settle(running)
        return running
    }

    /// Waits until nothing is being read, no job is running and every file system has named its
    /// places (an answer that came after the test had let the program go would reach a window
    /// without its shell).
    internal func settle(_ app: Running) async {
        await PanelWait.until {
            !app.shell.panelCoordinator.isLoading && !app.kernel.jobs.isBusy
                && app.shell.panelCoordinator.places.isComplete
        }
    }

    /// Waits until nothing is read, nothing waits to be read again and no job runs.
    internal func rest(_ app: Running) async {
        await PanelWait.until {
            !app.shell.panelCoordinator.isLoading && !app.left.hasPendingReread && !app.right.hasPendingReread
                && !app.kernel.jobs.isBusy
        }
    }

    /// Presses a key in the source panel; true when the panel took it.
    internal func press(_ app: Running, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        app.shell.panelCoordinator.sourcePanel.handleKey(Self.key(keyCode, "", flags))
    }

    /// The names of the listing the cache remembers for `path` of the memory file system.
    internal func remembered(_ app: Running, _ path: String) -> [String] {
        app.kernel.listingCache.entry(for: memory.url(path), showHidden: false)?.listing.items.map(\.name) ?? []
    }

    /// The tabs of a panel that shows `folder` of the sandbox.
    private func state(of folder: String) -> PanelTabs.State {
        PanelTabs.State(tabs: [.init(location: box.url(folder))], active: 0)
    }

    deinit {
        // Nothing to release: the sandbox removes its folder itself.
    }
}
