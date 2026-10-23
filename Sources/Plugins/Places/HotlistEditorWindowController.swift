import AFMKernel
import AFMShell
import AppKit

/// The "Change directory menu" dialog (spec 12 › Directory hotlist editor): the hotlist as a
/// list with its submenus indented, buttons to add, delete, rename and move entries, and the
/// command and target path of the selected entry.
///
/// It works on a copy of the list; only OK hands the copy back. Main thread only; nothing here
/// touches a file system.
internal final class HotlistEditorWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate
{
    /// The kernel, for the dialogs the editor asks with.
    private let kernel: Kernel
    /// The copy of the list being edited.
    private var hotlist: Hotlist
    /// The list's lines as the table shows them.
    private var rows: [Hotlist.Row] = []
    /// The command a new entry starts with: `cd` to the source panel's directory.
    private let proposedCommand: String
    /// The title a new entry starts with: the name of the source panel's directory.
    private let proposedTitle: String
    /// Whether the dialog ended with OK.
    private var accepted = false
    /// The controller's window, which it always has.
    private let dialog: NSWindow
    /// The list, the buttons and the fields.
    private let controls = HotlistEditorControls(
        addActions: [
            ("Add Item…", #selector(addItem)), ("Add Submenu…", #selector(addSubmenu)),
            ("Add Separator", #selector(addSeparator))
        ],
        entryActions: [
            ("Delete Item", #selector(deleteEntry)), ("Change Title…", #selector(changeTitle)),
            ("Move Up", #selector(moveEntryUp)), ("Move Down", #selector(moveEntryDown))
        ],
        cancel: #selector(cancel),
        accept: #selector(accept)
    )
    /// The list of entries.
    private var table: NSTableView { controls.table }

    /// The changed list after OK; nil before and after Cancel.
    internal var result: Hotlist? { accepted ? hotlist : nil }

    /// The path of the selected entry; nil when no line is selected.
    private var selectedPath: Hotlist.Path? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].path : nil
    }

    /// Where a new entry goes: right below the selected line, which is inside a submenu when
    /// that line is the submenu's title.
    private var insertionPath: Hotlist.Path {
        guard let path = selectedPath, let index = path.last, let entry = hotlist.entry(at: path) else {
            return [hotlist.entries.count]
        }
        return entry.kind == .submenu ? path + [0] : Array(path.dropLast()) + [index + 1]
    }

    /// An editor of a copy of `hotlist`; new entries lead to `currentDirectory`.
    internal init(_ hotlist: Hotlist, kernel: Kernel, currentDirectory: URL) {
        self.hotlist = hotlist
        self.kernel = kernel
        proposedCommand = "cd " + kernel.fileSystems.displayPath(currentDirectory)
        proposedTitle =
            currentDirectory.lastPathComponent.isEmpty
            ? kernel.fileSystems.displayPath(currentDirectory) : currentDirectory.lastPathComponent
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Change Directory Menu"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 340)
        dialog = window
        super.init(window: window)
        window.delegate = self
        connectControls()
        window.contentView = controls.content
        reload(selecting: hotlist.rows.first?.path)
    }

    /// Not used: the editor is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) { fatalError("not used") }

    /// Shows the editor and waits for it.
    ///
    /// Returns the changed list on OK, nil on Cancel.
    internal static func run(_ hotlist: Hotlist, kernel: Kernel, currentDirectory: URL) -> Hotlist? {
        let controller = HotlistEditorWindowController(hotlist, kernel: kernel, currentDirectory: currentDirectory)
        let window = controller.dialog
        window.center()
        NSApplication.shared.runModal(for: window)
        window.orderOut(nil)
        return controller.result
    }

    /// A line of the editor's list: indented by its depth, submenus with a mark of their own.
    nonisolated internal static func title(of row: Hotlist.Row) -> String {
        let indent = String(repeating: "      ", count: row.depth)
        switch row.entry.kind {
        case .separator:
            return indent + HotlistMenu.separatorTitle

        case .submenu:
            return indent + "▾ " + row.entry.title

        case .item:
            return indent + row.entry.title
        }
    }

    // MARK: Controls

    /// Makes the editor the target of the buttons, the list's data source and delegate and the fields' delegate.
    private func connectControls() {
        for button in controls.buttons {
            button.target = self
        }
        controls.hideBox.action = #selector(hidingChanged)
        controls.hideBox.state = hotlist.hidesMarked ? .on : .off
        controls.hideField.stringValue = hotlist.hideCharacter
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(toggleHidden)
        controls.table.onKey = { [weak self] event in self?.handleKey(event) == true }
        for field in [controls.commandField, controls.targetField, controls.hideField] {
            field.delegate = self
        }
    }

    // MARK: The list

    /// Shows the list again, with the line of `path` selected.
    private func reload(selecting path: Hotlist.Path?) {
        rows = hotlist.rows
        table.reloadData()
        if let row = rows.firstIndex(where: { $0.path == path }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        showSelection()
    }

    /// Shows the command and target of the selected entry and enables what can be done with it.
    private func showSelection() {
        let entry = selectedPath.flatMap(hotlist.entry(at:))
        let item = entry?.kind == .item ? entry : nil
        controls.commandField.stringValue = item?.command ?? ""
        controls.targetField.stringValue = item?.target ?? ""
        controls.commandField.isEnabled = item != nil
        controls.targetField.isEnabled = item != nil
        for button in controls.entryButtons {
            button.isEnabled = entry != nil
        }
        // "Change Title…": a separator has none.
        controls.entryButtons[1].isEnabled = entry != nil && entry?.kind != .separator
        controls.numberLabel.stringValue = rows.isEmpty ? "" : "Entry \(table.selectedRow + 1) of \(rows.count)"
    }

    /// Puts `entry` below the selected line, or tells the user the list is full.
    private func add(_ entry: HotlistEntry) {
        guard let path = hotlist.insert(entry, at: insertionPath) else {
            kernel.interaction.inform(
                "The directory menu is full.",
                detail: "It holds at most \(Hotlist.limit) entries.",
                style: .warning
            )
            return
        }
        reload(selecting: path)
    }

    /// "Add Item…": asks for a title; the entry leads to the source panel's directory.
    @objc
    private func addItem() {
        guard
            let title = kernel.interaction.prompt(
                "Title of the new entry:",
                value: proposedTitle,
                detail: "A single - makes a separator line."
            ),
            !title.isEmpty
        else { return }
        add(.titled(title, command: proposedCommand))
    }

    /// "Add Submenu…": asks for a title and adds an empty submenu.
    @objc
    private func addSubmenu() {
        guard let title = kernel.interaction.prompt("Title of the new submenu:"), !title.isEmpty else {
            return
        }
        add(.submenu(title))
    }

    /// "Add Separator".
    @objc
    private func addSeparator() {
        add(.separator)
    }

    /// "Delete Item": removes the selected entry; the line that takes its place is selected.
    @objc
    private func deleteEntry() {
        guard let path = selectedPath else {
            return
        }
        let row = table.selectedRow
        hotlist.remove(at: path)
        rows = hotlist.rows
        reload(selecting: rows.isEmpty ? nil : rows[min(row, rows.count - 1)].path)
    }

    /// "Change Title…": asks for a new title of the selected entry.
    @objc
    private func changeTitle() {
        guard let path = selectedPath, let entry = hotlist.entry(at: path), entry.kind != .separator,
            let title = kernel.interaction.prompt("New title:", value: entry.title), !title.isEmpty
        else { return }
        hotlist.update(at: path) { entry in entry.title = title }
        reload(selecting: path)
    }

    /// "Move Up" and Shift+Up.
    @objc
    private func moveEntryUp() { move(-1) }

    /// "Move Down" and Shift+Down.
    @objc
    private func moveEntryDown() { move(1) }

    /// Moves the selected entry one line (`Hotlist.move(at:by:)`).
    private func move(_ direction: Int) {
        guard let path = selectedPath else {
            return
        }
        reload(selecting: hotlist.move(at: path, by: direction))
    }

    /// A double click: hides or shows the selected entry.
    @objc
    private func toggleHidden() {
        guard let path = selectedPath else {
            return
        }
        hotlist.toggleHideMark(at: path)
        reload(selecting: path)
    }

    /// The hiding check box was clicked.
    @objc
    private func hidingChanged() {
        hotlist.hidesMarked = controls.hideBox.state == .on
    }

    /// Shift+Up, Shift+Down and Delete in the list; false for any other key.
    private func handleKey(_ event: NSEvent) -> Bool {
        if Shortcut(.upArrow, .shift).matches(event) {
            move(-1)
        } else if Shortcut(.downArrow, .shift).matches(event) {
            move(1)
        } else if Shortcut(.forwardDelete).matches(event) || Shortcut(.backspace, .command).matches(event) {
            deleteEntry()
        } else {
            return false
        }
        return true
    }

    /// The fields below the list belong to the selected entry and are taken over as typed.
    internal func controlTextDidChange(_ notification: Notification) {
        let field = notification.object as? NSTextField
        if field === controls.hideField {
            // Any character but the dash, which already means separators and submenus.
            let character = String(controls.hideField.stringValue.prefix(1))
            hotlist.hideCharacter = character == "-" ? "" : character
        } else if let path = selectedPath {
            // The command field, or else the target path's.
            hotlist.update(at: path) { entry in
                if field === controls.commandField {
                    entry.command = controls.commandField.stringValue
                } else {
                    entry.target = controls.targetField.stringValue
                }
            }
            rows = hotlist.rows
        }
    }

    /// One row per line of the list.
    internal func numberOfRows(in _: NSTableView) -> Int { rows.count }

    /// The cell of a line: its title, indented by its depth (`title(of:)`).
    internal func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("entry")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingTail
                return label
            }()
        cell.stringValue = Self.title(of: rows[row])
        return cell
    }

    /// Another line was selected: the fields show its entry.
    internal func tableViewSelectionDidChange(_: Notification) {
        showSelection()
    }

    // MARK: Result

    /// OK: the changed list is handed back.
    @objc
    private func accept() {
        // A field that is still being edited hands in its text first.
        window?.makeFirstResponder(nil)
        accepted = true
        close()
    }

    /// Cancel: nothing is handed back.
    @objc
    private func cancel() {
        close()
    }

    /// Ends the modal loop of the dialog, if it runs in one.
    internal func windowWillClose(_: Notification) {
        // Only the loop this window runs in is ended: a stop without one would end whatever
        // loop the main thread runs.
        if NSApplication.shared.modalWindow === window {
            NSApplication.shared.stopModal()
        }
    }
}
