import AFMContracts
import AFMKernel
import AppKit

/// The commands only the window can provide: moving the cursor, marking with the keyboard,
/// switching panels, the volume list and the in-place name editor. They are registered like
/// any plugin's commands, so their keys are in the key bindings and can be changed there
/// (spec 06 › Navigation, 06 › Selection).
@MainActor
enum ShellCommands {
    static func register(in kernel: Kernel, panels: PanelCoordinator) {
        let commands = kernel.commands
        let source = { panels.sourcePanel }
        let model = { panels.sourcePanel.model }
        /// Cursor keys change nothing but the cursor, so they also work while a job starts.
        func cursor(_ id: CommandID, _ title: String, _ shortcuts: [Shortcut], _ row: @escaping (PanelModel) -> Int) {
            commands.register(Command(id, title, shortcuts, runsDuringJobs: true)) {
                model().moveCursor(to: row(model()))
            }
        }

        // ← and → jump to the first and the last entry of the folder (`SpecialCursorMovement` 1
        // of the spec); `[..]` is not an entry, Home still reaches it.
        cursor(.cursorToFirstEntry, "Cursor to First Entry", [Shortcut(.leftArrow)]) {
            $0.hasParentRow && !$0.items.isEmpty ? 1 : 0
        }
        cursor(.cursorToLastEntry, "Cursor to Last Entry", [Shortcut(.rightArrow), Shortcut(.end)]) { $0.rowCount - 1 }
        cursor(.cursorToTop, "Cursor to Top", [Shortcut(.home)]) { _ in 0 }
        cursor(.cursorPageUp, "Cursor Page Up", [Shortcut(.pageUp)]) { $0.cursor - source().pageSize }
        cursor(.cursorPageDown, "Cursor Page Down", [Shortcut(.pageDown)]) { $0.cursor + source().pageSize }

        commands.register(Command(.toggleSelectionWithSize, "Select and Calculate Size", [Shortcut(.space)])) {
            source().toggleSelectionWithSize()
        }
        commands.register(
            Command(
                .toggleSelectionAndMoveDown,
                "Select and Move Down",
                [Shortcut(.insert), Shortcut(.downArrow, .shift)]
            )
        ) {
            source().toggleSelectionAndMove(1)
        }
        commands.register(Command(.toggleSelectionAndMoveUp, "Select and Move Up", [Shortcut(.upArrow, .shift)])) {
            source().toggleSelectionAndMove(-1)
        }

        commands.register(Command(.focusTarget, "Switch Panel", [Shortcut(.tab)], runsDuringJobs: true)) {
            panels.targetPanel.focus()
        }
        commands.register(Command(.leftVolumes, "Left Volume List", [.f(1, .option)])) {
            panels.leftPanel.showVolumeList()
        }
        commands.register(Command(.rightVolumes, "Right Volume List", [.f(2, .option)])) {
            panels.rightPanel.showVolumeList()
        }
        commands.register(Command(.editNameInPlace, "Edit Name in Place"), enabled: { model().cursorItem != nil }) {
            source().beginRename()
        }

        kernel.menus.add([.leftVolumes, .rightVolumes], to: .commandsVolumes)
    }
}
