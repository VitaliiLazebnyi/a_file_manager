import AFMContracts
import AFMKernel

/// The commands that move a panel through the directories it knows of (main thread).
///
/// The kernel keeps what is registered here; it must not be kept by it in turn, so every handler
/// holds it unowned.
extension NavigationPlugin {
    /// Open, Open Directory or Package, and the parent and root directories.
    internal func registerOpening(in owner: Kernel) {
        unowned let kernel = owner
        // Some handlers run other commands; the registry keeps them, so they hold it unowned.
        unowned let commands = kernel.commands
        let source = { kernel.panels.source }

        func goToParent() {
            if let parent = source().model.parentTarget { source().show(parent.location, focus: parent.focus) }
        }

        // Enter: `[..]` goes up, a folder is entered, a file goes to the first opener that takes it.
        func open(enterPackages: Bool) {
            let panel = source()
            guard let item = panel.model.cursorItem else {
                if panel.model.cursorIsOnParentRow { goToParent() }
                return
            }
            if item.isFolder || (enterPackages && item.isDirectory) {
                panel.show(item.url)
            } else if !kernel.openers.open(item, in: panel) {
                commands.onRejected()
            }
        }

        commands.register(Command(.open, "Open", [Shortcut(.returnKey), Shortcut(.enter), .cmd("o")])) {
            open(enterPackages: false)
        }
        commands.register(
            Command(
                .goToDirectory,
                "Open Directory or Package",
                [Shortcut(.downArrow, .command), Shortcut(.pageDown, .control)]
            )
        ) {
            open(enterPackages: true)
        }
        commands.register(
            Command(
                .goToParent,
                "Parent Directory",
                [Shortcut(.upArrow, .command), Shortcut(.backspace), Shortcut(.pageUp, .control)]
            ),
            enabled: { source().model.parentTarget != nil },
            goToParent
        )
        commands.register(
            Command(.goToRoot, "Root Directory", [.cmd("\\"), Shortcut(.character("\\"), .control)]),
            enabled: { source().model.rootTarget != nil },
            { if let root = source().model.rootTarget { source().show(root.location, focus: root.focus) } }
        )
    }

    /// Go Back and Go Forward through the source panel's history.
    internal func registerHistoryMoves(in owner: Kernel) {
        unowned let kernel = owner
        let source = { kernel.panels.source }
        kernel.commands.register(
            Command(.goBack, "Go Back", [.cmd("["), Shortcut(.leftArrow, .option)]),
            enabled: { source().model.backLocation != nil },
            { if let location = source().model.backLocation { source().show(location, history: .step(-1)) } }
        )
        kernel.commands.register(
            Command(.goForward, "Go Forward", [.cmd("]"), Shortcut(.rightArrow, .option)]),
            enabled: { source().model.forwardLocation != nil },
            { if let location = source().model.forwardLocation { source().show(location, history: .step(1)) } }
        )
    }

    /// Reread, Target = Source and back, and the transfers to one side.
    internal func registerPanelMoves(in owner: Kernel) {
        unowned let kernel = owner
        let source = { kernel.panels.source }
        let target = { kernel.panels.target }
        kernel.commands.register(
            Command(.reread, "Reread Source", [.cmd("r"), .f(2), Shortcut(.character("r"), .control)])
        ) {
            for panel in kernel.panels.all { panel.reload() }
        }
        kernel.commands.register(Command(.targetEqualsSource, "Target = Source")) {
            target().show(source().model.directory)
        }
        kernel.commands.register(Command(.sourceEqualsTarget, "Source = Target")) {
            source().show(target().model.directory)
        }
        // Ctrl+← / Ctrl+→: the folder under the cursor is shown in the panel on that side; when
        // the cursor is not on a folder, the current directory is. Pressed in the panel of that
        // very side, the panel takes the other panel's directory.
        func transfer(to panel: any PanelHandle) {
            let from = source()
            if from === panel {
                panel.show(target().model.directory)
            } else {
                panel.show(from.model.cursorItem.flatMap { $0.isFolder ? $0.url : nil } ?? from.model.directory)
            }
        }
        kernel.commands.register(
            Command(.transferLeft, "Show Folder in Left Panel", [Shortcut(.leftArrow, .control)])
        ) {
            transfer(to: kernel.panels.left)
        }
        kernel.commands.register(
            Command(.transferRight, "Show Folder in Right Panel", [Shortcut(.rightArrow, .control)])
        ) {
            transfer(to: kernel.panels.right)
        }
    }

    /// Next and Previous Volume: the neighbouring entry of the volume list, counted from where the
    /// source panel is; then Exchange Directories.
    internal func registerVolumeMoves(in owner: Kernel) {
        unowned let kernel = owner
        // Some handlers run other commands; the registry keeps them, so they hold it unowned.
        unowned let commands = kernel.commands
        let source = { kernel.panels.source }
        let target = { kernel.panels.target }
        func goToVolume(_ delta: Int) {
            let (providers, current, panel) = (kernel.fileSystems.all, source().model.directory, source())
            // The disks are asked in the background: the first answer can take a moment.
            kernel.jobs.run(
                title: "Go to volume",
                work: { _ -> Place? in
                    Self.neighbourPlace(of: current, in: providers.flatMap { $0.places() }, delta: delta)
                },
                // The registry is kept until the answer is in: the kernel may have gone by then.
                completion: { [commands] place in
                    guard let place else {
                        return commands.onRejected()
                    }
                    panel.show(place.url)
                }
            )
        }
        commands.register(Command(.nextVolume, "Next Volume")) { goToVolume(1) }
        commands.register(Command(.previousVolume, "Previous Volume")) { goToVolume(-1) }
        commands.register(
            Command(.exchangePanels, "Exchange Directories", [.cmd("u"), Shortcut(.character("u"), .control)])
        ) {
            let (sourceDirectory, targetDirectory) = (source().model.directory, target().model.directory)
            source().show(targetDirectory)
            target().show(sourceDirectory)
        }
    }
}
