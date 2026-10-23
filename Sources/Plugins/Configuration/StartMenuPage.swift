import AFMKernel
import AppKit

/// The Start-menu editor (spec 14 › The Change start menu dialog).
internal final class StartMenuPage: NSObject, OptionsPage {
    private unowned let center: ConfigurationCenter
    private var stored = StartMenuDraft()
    private var draft = StartMenuDraft()
    private let table = RowsTable(columns: [("Nr.", 34), ("Title", 170), ("Command", 190), ("Key", 80)])
    /// The page's name, "Start Menu".
    internal let title = "Start Menu"
    /// The list of the menu's entries and the buttons that change it.
    internal private(set) lazy var view: NSView = OptionsLayout.editor(
        table,
        buttons: [
            ActionButton("Add Item…") { [weak self] in self?.addItem() },
            ActionButton("Add Command…") { [weak self] in self?.addCommand() },
            ActionButton("Add Separator") { [weak self] in self?.add(StartMenuDraft.Row(entry: .separator)) },
            ActionButton("Change…") { [weak self] in self?.change() },
            ActionButton("Remove") { [weak self] in self?.removeSelected() },
            ActionButton("Move Up") { [weak self] in self?.move(-1) },
            ActionButton("Move Down") { [weak self] in self?.move(1) }
        ],
        below: [
            OptionsLayout.note(
                ConfigurationCenter.startMenuHint
                    + "\nThe n-th entry also runs as the command cm_UserMenu<n>. Submenus are not available."
            )
        ]
    )
    /// Called after every change of the menu.
    internal var onEdit: (() -> Void)?

    /// Whether the entries differ from the stored ones.
    internal var isChanged: Bool { draft != stored }

    /// A page that edits the Start menu of the center; a double click changes an entry.
    internal init(center: ConfigurationCenter) {
        self.center = center
        super.init()
        table.onActivate = { [weak self] in self?.change() }
    }

    private func reload(selecting row: Int?) {
        table.show(
            draft.rows.enumerated()
                .map { index, row in
                    row.entry.isSeparator
                        ? ["\(index + 1)", "———", "", ""]
                        : [
                            "\(index + 1)", row.entry.title, row.entry.action.command,
                            ShortcutText.parse(row.shortcut).map(ShortcutText.display) ?? ""
                        ]
                },
            symbols: [],
            selecting: row
        )
    }

    private func edited(selecting row: Int?) {
        reload(selecting: row)
        onEdit?()
    }

    private func add(_ row: StartMenuDraft.Row?) {
        guard let row else {
            return
        }
        edited(selecting: draft.insert(row, after: table.selectedRow))
    }

    private func addItem() {
        add(center.editStartMenuRow(nil, proposing: CommandAction(), title: ""))
    }

    private func addCommand() {
        guard let picked = center.pickCommand() else {
            return
        }
        add(center.editStartMenuRow(nil, proposing: CommandAction(command: picked.id.rawValue), title: picked.title))
    }

    private func change() {
        guard let index = table.selectedRow, draft.rows.indices.contains(index), !draft.rows[index].entry.isSeparator
        else {
            center.effects.beep()
            return
        }
        guard let row = center.editStartMenuRow(draft.rows[index], proposing: CommandAction(), title: "") else {
            return
        }
        draft.rows[index] = row
        edited(selecting: index)
    }

    private func removeSelected() {
        guard let row = table.selectedRow else {
            center.effects.beep()
            return
        }
        draft.rows.remove(at: row)
        edited(selecting: row)
    }

    private func move(_ offset: Int) {
        guard let row = table.selectedRow else {
            center.effects.beep()
            return
        }
        edited(selecting: draft.move(row, by: offset))
    }

    /// Stores the entries, when they were changed, and starts again from them.
    internal func commit() {
        guard isChanged else {
            return
        }
        center.commit(draft)
        discard()
    }

    /// Drops the changes and shows the stored entries.
    internal func discard() {
        stored = center.startMenuDraft()
        draft = stored
        reload(selecting: nil)
    }
}
