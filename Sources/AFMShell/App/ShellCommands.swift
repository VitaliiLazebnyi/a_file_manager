import AFMContracts
import AFMKernel

/// The commands only the window can provide.
///
/// Moving the cursor, marking with the keyboard, switching panels, the volume list and the
/// in-place name editor. They are registered like
/// any plugin's commands, so their keys are in the key bindings and can be changed there
/// (spec 06 › Navigation, 06 › Selection).
///
/// The kernel keeps what is registered here, and the panels keep the kernel: the commands hold
/// the panels weakly, so neither keeps the other alive.
@MainActor
internal enum ShellCommands {
    /// Registers the commands with `kernel`, acting on `panels`.
    ///
    /// Main thread, while the shell is built.
    internal static func register(in kernel: Kernel, panels: PanelCoordinator) {
        let source = { [weak panels] in panels?.sourcePanel }
        registerCursorCommands(in: kernel.commands, source: source)
        registerSelectionCommands(in: kernel.commands, source: source)
        registerPanelCommands(in: kernel.commands, panels: panels, source: source)
        kernel.menus.add([.leftVolumes, .rightVolumes], to: .commandsVolumes)
    }

    /// The keys that move the cursor.
    ///
    /// They change nothing but the cursor, so they also work while a job starts.
    private static func registerCursorCommands(
        in commands: CommandRegistry,
        source: @escaping () -> PanelViewController?
    ) {
        func cursor(
            _ id: CommandID,
            _ title: String,
            _ shortcuts: [Shortcut],
            _ row: @escaping (PanelViewController) -> Int
        ) {
            commands.register(Command(id, title, shortcuts, runsDuringJobs: true)) {
                guard let panel = source() else {
                    return
                }
                panel.model.moveCursor(to: row(panel))
            }
        }
        // ← and → jump to the first and the last entry of the folder (`SpecialCursorMovement` 1
        // of the spec); `[..]` is not an entry, Home still reaches it.
        cursor(.cursorToFirstEntry, "Cursor to First Entry", [Shortcut(.leftArrow)]) { panel in
            panel.model.hasParentRow && !panel.model.items.isEmpty ? 1 : 0
        }
        cursor(.cursorToLastEntry, "Cursor to Last Entry", [Shortcut(.rightArrow), Shortcut(.end)]) { panel in
            panel.model.rowCount - 1
        }
        cursor(.cursorToTop, "Cursor to Top", [Shortcut(.home)]) { _ in 0 }
        cursor(.cursorPageUp, "Cursor Page Up", [Shortcut(.pageUp)]) { panel in
            panel.model.cursor - panel.pageSize
        }
        cursor(.cursorPageDown, "Cursor Page Down", [Shortcut(.pageDown)]) { panel in
            panel.model.cursor + panel.pageSize
        }
    }

    /// Marking with the keyboard.
    private static func registerSelectionCommands(
        in commands: CommandRegistry,
        source: @escaping () -> PanelViewController?
    ) {
        commands.register(Command(.toggleSelectionWithSize, "Select and Calculate Size", [Shortcut(.space)])) {
            source()?.toggleSelectionWithSize()
        }
        commands.register(
            Command(
                .toggleSelectionAndMoveDown,
                "Select and Move Down",
                [Shortcut(.insert), Shortcut(.downArrow, .shift)]
            )
        ) {
            source()?.toggleSelectionAndMove(1)
        }
        commands.register(Command(.toggleSelectionAndMoveUp, "Select and Move Up", [Shortcut(.upArrow, .shift)])) {
            source()?.toggleSelectionAndMove(-1)
        }
    }

    /// Switching panels, the volume lists and the in-place name editor.
    private static func registerPanelCommands(
        in commands: CommandRegistry,
        panels: PanelCoordinator,
        source: @escaping () -> PanelViewController?
    ) {
        let switchPanel = Command(.focusTarget, "Switch Panel", [Shortcut(.tab)], runsDuringJobs: true)
        commands.register(switchPanel) { [weak panels] in panels?.targetPanel.focus() }
        commands.register(Command(.leftVolumes, "Left Volume List", [.f(1, .option)])) { [weak panels] in
            panels?.leftPanel.showVolumeList()
        }
        commands.register(Command(.rightVolumes, "Right Volume List", [.f(2, .option)])) { [weak panels] in
            panels?.rightPanel.showVolumeList()
        }
        commands.register(
            Command(.editNameInPlace, "Edit Name in Place"),
            enabled: { source()?.model.cursorItem != nil },
            { source()?.beginRename() }
        )
    }
}
