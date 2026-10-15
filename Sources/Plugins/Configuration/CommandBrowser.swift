import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The *Choose command* dialog (spec 14 › The Choose command dialog): every command with its
/// name, title and keys, a live filter, and the management of user commands. Opened on its own
/// it runs the chosen command; the editors use it to pick one. Main thread only.
///
/// The categories are the menus the commands are in; this program has no `totalcmd.inc` with
/// numbers, so the Nr. column is replaced by the keys.
final class CommandBrowserController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private final class Window: ToolWindow {
        var onCopy: (() -> Bool)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if Shortcut.cmd("c").matches(event), onCopy?() == true { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    private unowned let center: ConfigurationCenter
    private let table = RowsTable(columns: [("Command", 190), ("Title", 250), ("Keys", 130)])
    private let filter = NSSearchField()
    private let categories = NSPopUpButton(frame: .zero, pullsDown: false)
    private var primaryButton = NSButton()
    private var userButtons: [NSButton] = []
    private(set) var rows: [CommandRow] = []
    private var isPicking = false
    private var picked: CommandID?

    init(center: ConfigurationCenter) {
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

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private func buildContent(in window: NSWindow) {
        filter.placeholderString = "Filter"
        filter.delegate = self
        filter.target = self
        filter.action = #selector(filterAccepted)
        categories.target = self
        categories.action = #selector(categoryChanged)
        table.onSelect = { [weak self] in self?.updateButtons() }
        table.onActivate = { [weak self] in self?.accept() }
        let top = filledStack([categories, filter], vertical: false)
        primaryButton = ActionButton("Run") { [unowned self] in accept() }
        primaryButton.keyEquivalent = "\r"
        userButtons = [
            ActionButton("New…") { [unowned self] in
                guard let command = center.editUserCommand(nil) else { return }
                reload(selecting: command.id)
            },
            ActionButton("Edit…") { [unowned self] in
                guard let existing = selectedUserCommand, let command = center.editUserCommand(existing) else { return }
                reload(selecting: command.id)
            },
            ActionButton("Delete") { [unowned self] in deleteSelected() },
            ActionButton("Rename/Copy…") { [unowned self] in renameOrCopy() }
        ]
        let bottom = filledStack(
            userButtons + [spacer(), ActionButton("Cancel") { [unowned self] in self.window?.close() }, primaryButton],
            vertical: false
        )
        window.contentView = padded(filledStack([top, table, bottom], vertical: true, spacing: 10), by: 12)
    }

    // MARK: Showing

    /// Opens the dialog on its own: the chosen command is run.
    func show(category: String? = nil) {
        prepare(picking: false, category: category)
        showWindow(nil)
        window?.makeFirstResponder(filter)
    }

    /// Runs the dialog for an editor; nil when the user cancelled.
    func pick() -> CommandID? {
        guard let window, !isPicking else { return nil }
        if window.isVisible { window.orderOut(nil) }
        prepare(picking: true, category: nil)
        window.makeFirstResponder(filter)
        NSApp.runModal(for: window)
        isPicking = false
        window.orderOut(nil)
        return picked
    }

    /// Everything `show` and `pick` do short of putting the window on screen.
    func prepare(picking: Bool, category: String?) {
        isPicking = picking
        picked = nil
        primaryButton.title = picking ? "OK" : "Run"
        filter.stringValue = ""
        let all = center.commandRows()
        categories.removeAllItems()
        categories.addItems(
            withTitles: ["All"] + CommandCatalog.categories(of: all, menus: center.kernel.menus.menus) + [
                CommandRow.userCategory
            ]
        )
        if categories.itemTitles.filter({ $0 == CommandRow.userCategory }).count > 1 {
            categories.removeItem(at: categories.numberOfItems - 1)
        }
        categories.selectItem(withTitle: category ?? "All")
        reload()
    }

    private func reload(selecting id: CommandID? = nil) {
        let category = categories.indexOfSelectedItem > 0 ? categories.titleOfSelectedItem : nil
        rows = CommandCatalog.filter(center.commandRows(), text: filter.stringValue, category: category)
            .filter {
                !$0.id.rawValue.hasPrefix(UserCommand.prefix) || center.userCommand(named: $0.id.rawValue) != nil
            }
        table.show(
            rows.map { [$0.id.rawValue, $0.title, $0.keys] },
            selecting: id.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        )
        updateButtons()
    }

    private var selected: CommandRow? { table.selectedRow.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }
    private var selectedUserCommand: UserCommand? { selected.flatMap { center.userCommand(named: $0.id.rawValue) } }

    private func updateButtons() {
        primaryButton.isEnabled = selected != nil
        for button in userButtons.dropFirst() { button.isEnabled = selectedUserCommand != nil }
    }

    func controlTextDidChange(_: Notification) { reload() }
    @objc private func categoryChanged() { reload() }
    @objc private func filterAccepted() { accept() }

    // MARK: Actions

    /// OK, Return or a double click: hands the command to the editor, or runs it.
    private func accept() {
        guard let row = selected else {
            NSSound.beep()
            return
        }
        if isPicking {
            picked = row.id
            NSApp.stopModal()
        } else {
            window?.close()
            center.kernel.commands.perform(row.id)
        }
    }

    /// Cmd+C in the list copies the command's name (spec 14 › Elements).
    private func copyName() -> Bool {
        guard let row = selected, window?.firstResponder === table.tableView else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.id.rawValue, forType: .string)
        return true
    }

    private func deleteSelected() {
        guard let command = selectedUserCommand else { return }
        let answer = center.kernel.interaction.choose(
            "Delete the user command \(command.name)?",
            detail: "Buttons, menu entries and keys that use it stop working.",
            buttons: ["Delete", "Cancel"],
            style: .warning
        )
        guard answer == 0 else { return }
        center.removeUserCommand(named: command.name)
        reload()
    }

    private func renameOrCopy() {
        guard let command = selectedUserCommand else { return }
        let ui = center.kernel.interaction
        guard
            let answer = ui.form(
                "Rename or Copy \(command.name)",
                detail: "",
                fields: [.text("name", "New name:  em_", String(command.name.dropFirst(UserCommand.prefix.count)))],
                buttons: ["Rename", "Copy"]
            )
        else { return }
        guard let name = UserCommand.name(from: answer.text("name")), center.userCommand(named: name) == nil else {
            ui.inform(
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

    func windowWillClose(_: Notification) {
        if isPicking { NSApp.stopModal() }
    }
}

extension ConfigurationCenter {
    /// Lets the user pick a command for an editor (the magnifier button of spec 14).
    func pickCommand() -> CommandID? {
        browser().pick()
    }

    func browser() -> CommandBrowserController {
        if let browserWindow { return browserWindow }
        let controller = CommandBrowserController(center: self)
        browserWindow = controller
        return controller
    }

    func showOptions(_ section: OptionsWindowController.Section) {
        let controller = optionsWindow ?? OptionsWindowController(center: self)
        optionsWindow = controller
        controller.show(section)
    }

    func showText(_ text: String, title: String) {
        let controller = textWindows[title] ?? TextWindowController(title: title)
        textWindows[title] = controller
        controller.show(text)
    }

    func closeWindows() {
        optionsWindow?.close()
        browserWindow?.close()
        textWindows.values.forEach { $0.close() }
    }

    /// The keyboard help, from the bindings in force (spec 17 › Help, `cm_Keyboard`).
    func keyboardHelp() -> String {
        "Keyboard shortcuts of \(kernel.productName)\nChange them in Configuration › Options › Keyboard.\n\n"
            + CommandCatalog.shortcutSheet(commandRows(), menus: kernel.menus.menus)
    }

    /// Where the things a Total Commander user looks for are in this program.
    func whatIsWhere() -> String {
        """
        \(kernel.productName): what is where

        Options            Configuration › Options (⌘,). The pages come from the program's
                           parts; changes apply with Apply or OK.
        Keys               Options › Keyboard: select a command, press Set Shortcut and
                           then the key. A key that is in use names its command first.
                           Help › Keyboard Shortcuts lists the keys in force.
        Button bar         Options › Button Bar: add commands and separators, reorder,
                           choose a symbol, or go back to the default bar.
        User commands      Configuration › User Commands: commands of your own (em_name)
                           that run a program, a shell line, cd <folder> or other
                           commands, with parameters such as %P %N %S %L. They can be
                           given keys, put on the button bar and typed on the command line.
        Start menu         Options › Start Menu. The n-th entry is also cm_UserMenu<n>.
        All commands       Configuration › Choose Command lists every command with its
                           name and keys, and runs the one you choose.
        Settings           They are kept in the macOS preferences and stored the moment
                           they change; there is no wincmd.ini. Options › Settings File
                           exports them to a file, imports them and resets them.
        Language           The program is in English. Total Commander's language files
                           (.LNG, .MNU) are Windows resources and are not read.
        Not on the Mac     Run as administrator (*), 8.3 short names (the lower-case
                           parameter codes insert the long names), icon libraries
                           (buttons use system symbols), submenus in the Start menu.
        """
    }
}
