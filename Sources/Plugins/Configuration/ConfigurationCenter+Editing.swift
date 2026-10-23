import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The definition dialogs of user commands and Start-menu entries, and the Start menu as a draft.
extension ConfigurationCenter {
    /// The fields of the definition dialog, filled in with `existing`.
    private static func userCommandFields(_ existing: UserCommand?, shortcut: String) -> [FormField] {
        let action = existing?.action ?? CommandAction()
        return [
            .text("name", "Name:  em_", existing.map { String($0.name.dropFirst(UserCommand.prefix.count)) } ?? ""),
            .text("title", "Title:", existing?.title ?? ""),
            .text("command", "Command:", action.command),
            .text("parameters", "Parameters:", action.parameters),
            .text("path", "Start path:", action.startPath),
            .text("shortcut", "Shortcut:", shortcut),
            .text("symbol", "Symbol:", existing?.symbol ?? ""),
            .note(
                "Command: a command of the program (cm_…, several separated by commas), cd <folder>, "
                    + "or a program or shell line.\n"
                    + "Shortcut: for example ctrl+shift+n or f9.  "
                    + "Symbol: the name of a system symbol for the button bar.\n"
                    + startMenuHint
            )
        ]
    }

    /// The definition dialog of a user command (spec 14 › Defining).
    ///
    /// Nil when the user gave up or the name cannot be used.
    internal func editUserCommand(_ existing: UserCommand?) -> UserCommand? {
        let keys = existing.map { kernel.keyBindings.shortcuts(for: $0.id) } ?? []
        guard
            let answer = kernel.interaction.form(
                existing == nil ? "New User Command" : "Edit User Command",
                fields: Self.userCommandFields(existing, shortcut: keys.first?.notation ?? "")
            ),
            let name = usableName(answer.text("name"), replacing: existing)
        else { return nil }
        let command = UserCommand(
            name: name,
            title: answer.text("title").trimmingCharacters(in: .whitespaces),
            action: CommandAction(
                command: answer.text("command").trimmingCharacters(in: .whitespaces),
                parameters: answer.text("parameters"),
                startPath: answer.text("path").trimmingCharacters(in: .whitespaces)
            ),
            symbol: answer.text("symbol").trimmingCharacters(in: .whitespaces)
        )
        save(command, replacing: existing?.name)
        if answer.text("shortcut") != (keys.first?.notation ?? "") || name != existing?.name {
            setShortcut(answer.text("shortcut"), for: command.id)
        }
        return command
    }

    /// The name the user typed as it is stored; nil, and the user told, when it cannot be used
    /// or another command has it.
    private func usableName(_ text: String, replacing existing: UserCommand?) -> String? {
        guard let name = UserCommand.name(from: text) else {
            kernel.interaction.inform(
                "The command needs a name",
                detail: "Use letters, digits and the underscore.",
                style: .warning
            )
            return nil
        }
        if name != existing?.name, userCommand(named: name) != nil {
            kernel.interaction.inform(
                "\(name) exists already",
                detail: "Choose another name, or edit that command.",
                style: .warning
            )
            return nil
        }
        return name
    }

    /// The Start menu with the keys its entries have now.
    internal func startMenuDraft() -> StartMenuDraft {
        StartMenuDraft(
            rows: store.startMenu.enumerated()
                .map { index, entry in
                    StartMenuDraft.Row(
                        entry: entry,
                        shortcut: kernel.keyBindings.shortcuts(for: StartMenuEntry.commandID(at: index)).first?.notation
                            ?? ""
                    )
                }
        )
    }

    /// The entries as the menu registry takes them at start-up: one section per run of entries
    /// between separators.
    internal func startMenuSections() -> [[CommandID]] {
        var sections: [[CommandID]] = [[]]
        for (index, entry) in store.startMenu.enumerated() {
            if entry.isSeparator {
                sections.append([])
            } else {
                sections[sections.count - 1].append(StartMenuEntry.commandID(at: index))
            }
        }
        return sections.filter { !$0.isEmpty }
    }

    /// The dialog of one Start-menu entry (spec 14 › The Change start menu dialog).
    ///
    /// A new entry (`row` nil) starts with `proposal` and `proposedTitle`. Nil when the user gave up
    /// or left the title empty.
    internal func editStartMenuRow(
        _ row: StartMenuDraft.Row?,
        proposing proposal: CommandAction,
        title proposedTitle: String
    ) -> StartMenuDraft.Row? {
        let action = row?.entry.action ?? proposal
        let fields: [FormField] = [
            .text("title", "Title:", row?.entry.title ?? proposedTitle),
            .text("command", "Command:", action.command),
            .text("parameters", "Parameters:", action.parameters),
            .text("path", "Start path:", action.startPath),
            .text("shortcut", "Shortcut key:", row?.shortcut ?? ""),
            .note(Self.startMenuHint)
        ]
        guard
            let answer = kernel.interaction.form(
                row == nil ? "Add Start Menu Item" : "Change Start Menu Item",
                fields: fields
            )
        else { return nil }
        let title = answer.text("title").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            return nil
        }
        var shortcut = answer.text("shortcut").trimmingCharacters(in: .whitespaces)
        if !shortcut.isEmpty, ShortcutText.parse(shortcut) == nil {
            kernel.interaction.inform(
                "“\(shortcut)” is not a shortcut",
                detail: "Write it like ctrl+shift+n or f9.",
                style: .warning
            )
            shortcut = ""
        }
        let entry = StartMenuEntry(
            title: title,
            action: CommandAction(
                command: answer.text("command").trimmingCharacters(in: .whitespaces),
                parameters: answer.text("parameters"),
                startPath: answer.text("path").trimmingCharacters(in: .whitespaces)
            )
        )
        return StartMenuDraft.Row(entry: entry, shortcut: ShortcutText.parse(shortcut)?.notation ?? "")
    }
}
