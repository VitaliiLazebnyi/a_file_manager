import AFMKernel
import AppKit

/// The button-bar editor (spec 14 › The Change button bar dialog), as a list.
internal final class ButtonBarPage: NSObject, OptionsPage {
    private unowned let center: ConfigurationCenter
    private let editor: ToolbarEditor
    private let table = RowsTable(columns: [("Button", 250), ("Command", 200)])
    /// The page's name, "Button Bar".
    internal let title = "Button Bar"
    /// The list of the bar's buttons and the buttons that change it.
    internal private(set) lazy var view: NSView = OptionsLayout.editor(
        table,
        buttons: [
            ActionButton("Add Command…") { [weak self] in self?.addCommand() },
            ActionButton("Add Separator") { [weak self] in self?.insert(nil) },
            ActionButton("Add Line Break") { [weak self] in self?.insert(ToolbarRegistry.lineBreak) },
            ActionButton("Remove") { [weak self] in self?.removeSelected() },
            ActionButton("Move Up") { [weak self] in self?.move(-1) },
            ActionButton("Move Down") { [weak self] in self?.move(1) },
            ActionButton("Symbol…") { [weak self] in self?.chooseSymbol() },
            ActionButton("Reset to Default") { [weak self] in self?.resetToDefault() }
        ],
        below: [
            OptionsLayout.note(
                "A new button goes directly after the selected one. "
                    + "A program with parameters goes on the bar as a user command "
                    + "(Configuration › User Commands)."
            )
        ]
    )
    /// Called after every change of the bar.
    internal var onEdit: (() -> Void)?

    /// Whether the bar differs from the stored one.
    internal var isChanged: Bool { editor.isChanged }

    /// A page that edits the button bar of the center's kernel.
    internal init(center: ConfigurationCenter) {
        self.center = center
        editor = ToolbarEditor(toolbar: center.kernel.toolbar, settings: center.kernel.settings, store: center.store)
        super.init()
    }

    private func reload(selecting row: Int?) {
        let commands = center.kernel.commands
        table.show(
            editor.items.map { id in
                guard let id else {
                    return ["———", ""]
                }
                return id == ToolbarRegistry.lineBreak
                    ? ["═══ New line ═══", ""] : [commands[id]?.title ?? "(unknown command)", id.rawValue]
            },
            symbols: editor.items.map { id in
                id.flatMap { $0 == ToolbarRegistry.lineBreak ? nil : editor.symbol(for: $0) }
            },
            selecting: row
        )
    }

    private func edited(selecting row: Int?) {
        reload(selecting: row)
        onEdit?()
    }

    private func addCommand() {
        guard let picked = center.pickCommand() else {
            return
        }
        insert(picked.id)
    }

    /// Puts a button (nil: a separator) after the selected one.
    private func insert(_ id: CommandID?) {
        edited(selecting: editor.insert(id, after: table.selectedRow))
    }

    private func removeSelected() {
        guard let row = table.selectedRow else {
            center.effects.beep()
            return
        }
        editor.remove(at: row)
        edited(selecting: row)
    }

    private func move(_ offset: Int) {
        guard let row = table.selectedRow else {
            center.effects.beep()
            return
        }
        edited(selecting: editor.move(row, by: offset))
    }

    private func resetToDefault() {
        editor.resetToDefault()
        edited(selecting: nil)
    }

    /// The picture of a button is a system symbol, chosen by its name.
    private func chooseSymbol() {
        guard let row = table.selectedRow, editor.items.indices.contains(row), let id = editor.items[row],
            id != ToolbarRegistry.lineBreak
        else {
            center.effects.beep()
            return
        }
        let interaction = center.kernel.interaction
        guard
            let name = interaction.prompt(
                "Symbol for “\(center.kernel.commands[id]?.title ?? id.rawValue)”:",
                value: editor.symbol(for: id),
                detail:
                    "The name of a system symbol (SF Symbols), such as folder.badge.plus. Empty: the command's own."
            )?
            .trimmingCharacters(in: .whitespaces)
        else { return }
        guard name.isEmpty || NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            interaction.inform(
                "No symbol is called “\(name)”",
                detail: "The SF Symbols app lists the names.",
                style: .warning
            )
            return
        }
        editor.setSymbol(name, for: id)
        edited(selecting: row)
    }

    /// Stores the bar and applies it to the program.
    internal func commit() { editor.commit() }

    /// Drops the changes and shows the stored bar.
    internal func discard() {
        editor.discard()
        reload(selecting: nil)
    }
}
