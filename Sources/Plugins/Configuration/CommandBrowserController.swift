import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The *Choose command* dialog (spec 14 › The Choose command dialog): every command with its
/// name, title and keys, a live filter, and the management of user commands.
///
/// Opened on its own it runs the chosen command; the editors use it to pick one. Main thread only.
///
/// The categories are the menus the commands are in; this program has no `totalcmd.inc` with
/// numbers, so the Nr. column is replaced by the keys.
internal final class CommandBrowserController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    /// The dialog's window: Cmd+C goes to `onCopy` before the menus see it.
    private final class Window: ToolWindow {
        /// Copies the selected command's name; true when it did.
        var onCopy: (() -> Bool)?

        /// Cmd+C copies through `onCopy` when that copies something; other keys go the usual way.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if Shortcut.cmd("c").matches(event), onCopy?() == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    private unowned let center: ConfigurationCenter
    private let table = RowsTable(columns: [("Command", 190), ("Title", 250), ("Keys", 130)])
    private let filter = NSSearchField()
    private let categories = NSPopUpButton(frame: .zero, pullsDown: false)
    private var primaryButton = NSButton()
    private var userButtons: [NSButton] = []
    /// The commands the list shows, after the filter and the category.
    internal private(set) var rows: [CommandRow] = []
    private var isPicking = false
    private var picked: CommandRow?

    private var selected: CommandRow? { table.selectedRow.flatMap { rows.dropFirst($0).first } }
    private var selectedUserCommand: UserCommand? { selected.flatMap { center.userCommand(named: $0.id.rawValue) } }

    /// Makes the dialog (not yet on screen) for the center's commands.
    internal init(center: ConfigurationCenter) {
        self.center = center
        let window = Window(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Choose Command"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 320)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onCopy = { [weak self] in self?.copyName() ?? false }
        buildContent(in: window)
    }

    /// Not used: the dialog is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) { fatalError("not used") }

    private func buildContent(in window: NSWindow) {
        filter.placeholderString = "Filter"
        // Return in the filter is the delegate's (`control(_:textView:doCommandBy:)`): the field
        // sends no action of its own, since a search field sends it while the user types, which
        // ran the first command of a list that was still being narrowed down.
        filter.delegate = self
        categories.target = self
        categories.action = #selector(categoryChanged)
        table.onSelect = { [weak self] in self?.updateButtons() }
        table.onActivate = { [weak self] in self?.accept() }
        let top = filledStack([categories, filter], vertical: false, spacing: 8)
        primaryButton = ActionButton("Run") { [weak self] in self?.accept() }
        primaryButton.keyEquivalent = "\r"
        userButtons = [
            ActionButton("New…") { [weak self] in self?.newCommand() },
            ActionButton("Edit…") { [weak self] in self?.editSelected() },
            ActionButton("Delete") { [weak self] in self?.deleteSelected() },
            ActionButton("Rename/Copy…") { [weak self] in self?.renameOrCopy() }
        ]
        let bottom = filledStack(
            userButtons + [spacer(), ActionButton("Cancel") { [weak self] in self?.window?.close() }, primaryButton],
            vertical: false,
            spacing: 8
        )
        window.contentView = padded(filledStack([top, table, bottom], vertical: true, spacing: 10), by: 12)
    }

    // MARK: Showing

    /// Opens the dialog on its own: the chosen command is run.
    internal func show(category: String?) {
        prepare(picking: false, category: category)
        center.effects.present(self)
        window?.makeFirstResponder(filter)
    }

    /// Runs the dialog for an editor; nil when the user cancelled.
    internal func pick() -> CommandRow? {
        guard let window, !isPicking else {
            return nil
        }
        window.orderOut(nil)
        prepare(picking: true, category: nil)
        window.makeFirstResponder(filter)
        center.effects.runModal(window)
        isPicking = false
        window.orderOut(nil)
        return picked
    }

    /// Everything `show` and `pick` do short of putting the window on screen.
    internal func prepare(picking: Bool, category: String?) {
        isPicking = picking
        picked = nil
        primaryButton.title = picking ? "OK" : "Run"
        filter.stringValue = ""
        let all = center.commandRows()
        categories.removeAllItems()
        // The user commands' category is always offered, last; a pop-up holds a title once (an
        // item added again moves to the end).
        categories.addItems(
            withTitles: ["All"] + CommandCatalog.categories(of: all, menus: center.kernel.menus.menus) + [
                CommandRow.userCategory
            ]
        )
        categories.selectItem(withTitle: category ?? "All")
        reload()
    }

    private func reload(selecting id: CommandID? = nil) {
        let category = categories.indexOfSelectedItem > 0 ? categories.titleOfSelectedItem : nil
        rows = CommandCatalog.filter(center.commandRows(), text: filter.stringValue, category: category)
            .filter { row in
                !row.id.rawValue.hasPrefix(UserCommand.prefix) || center.userCommand(named: row.id.rawValue) != nil
            }
        table.show(
            rows.map { [$0.id.rawValue, $0.title, $0.keys] },
            symbols: [],
            selecting: id.flatMap { wanted in rows.firstIndex { $0.id == wanted } } ?? 0
        )
        updateButtons()
    }

    private func updateButtons() {
        primaryButton.isEnabled = selected != nil
        for button in userButtons.dropFirst() { button.isEnabled = selectedUserCommand != nil }
    }

    /// Each change of the filter narrows the list again.
    internal func controlTextDidChange(_: Notification) { reload() }

    @objc
    private func categoryChanged() { reload() }

    /// Return in the filter runs (or picks) the selected command; other keys edit the filter.
    internal func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        accept()
        return true
    }

    // MARK: Actions

    /// OK, Return or a double click: hands the command to the editor, or runs it.
    private func accept() {
        guard let row = selected else {
            center.effects.beep()
            return
        }
        if isPicking {
            picked = row
            center.effects.stopModal()
        } else {
            window?.close()
            center.kernel.commands.perform(row.id)
        }
    }

    /// Cmd+C in the list copies the command's name (spec 14 › Elements).
    private func copyName() -> Bool {
        guard let row = selected, window?.firstResponder === table.tableView else {
            return false
        }
        center.effects.pasteboard.clearContents()
        center.effects.pasteboard.setString(row.id.rawValue, forType: .string)
        return true
    }

    private func newCommand() {
        guard let command = center.editUserCommand(nil) else {
            return
        }
        reload(selecting: command.id)
    }

    private func editSelected() {
        guard let existing = selectedUserCommand, let command = center.editUserCommand(existing) else {
            return
        }
        reload(selecting: command.id)
    }

    private func deleteSelected() {
        guard let command = selectedUserCommand else {
            return
        }
        let answer = center.kernel.interaction.choose(
            "Delete the user command \(command.name)?",
            detail: "Buttons, menu entries and keys that use it stop working.",
            buttons: ["Delete", "Cancel"],
            style: .warning
        )
        guard answer == 0 else {
            return
        }
        center.removeUserCommand(named: command.name)
        reload()
    }

    private func renameOrCopy() {
        guard let command = selectedUserCommand else {
            return
        }
        let interaction = center.kernel.interaction
        guard
            let answer = interaction.form(
                "Rename or Copy \(command.name)",
                detail: "",
                fields: [.text("name", "New name:  em_", String(command.name.dropFirst(UserCommand.prefix.count)))],
                buttons: ["Rename", "Copy"]
            )
        else { return }
        guard let name = UserCommand.name(from: answer.text("name")), center.userCommand(named: name) == nil else {
            interaction.inform(
                "The name cannot be used",
                detail: "It is empty, in use, or has characters other than letters, digits and _.",
                style: .warning
            )
            return
        }
        var renamed = command
        renamed.name = name
        center.save(renamed, replacing: answer.button == 0 ? command.name : nil)
        reload(selecting: renamed.id)
    }

    /// Closing the window while an editor waits for a pick ends the modal run (nothing picked).
    internal func windowWillClose(_: Notification) {
        if isPicking { center.effects.stopModal() }
    }
}
