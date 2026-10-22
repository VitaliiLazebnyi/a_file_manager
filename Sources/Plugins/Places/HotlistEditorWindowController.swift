import AFMKernel
import AFMShell
import AppKit

/// The "Change directory menu" dialog (spec 12 › Directory hotlist editor): the hotlist as a
/// list with its submenus indented, buttons to add, delete, rename and move entries, and the
/// command and target path of the selected entry.
///
/// It works on a copy of the list; only OK hands the copy back. Main thread only; nothing here
/// touches a file system.
final class HotlistEditorWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate
{
    private final class EntryTableView: NSTableView {
        var onKey: ((NSEvent) -> Bool)?

        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }

    private let kernel: Kernel
    private var hotlist: Hotlist
    private var rows: [Hotlist.Row] = []
    /// The command a new entry starts with: `cd` to the source panel's directory.
    private let proposedCommand: String
    private let proposedTitle: String
    private var accepted = false
    /// The controller's window, which it always has.
    private let dialog: NSWindow

    private let table = EntryTableView()
    private let numberLabel = NSTextField(labelWithString: "")
    private let commandField = NSTextField()
    private let targetField = NSTextField()
    private let hideBox = NSButton(
        checkboxWithTitle: "Hide menu items starting with this character:",
        target: nil,
        action: nil
    )
    private let hideField = NSTextField()
    private var entryButtons: [NSButton] = []

    /// Shows the editor and waits for it.
    ///
    /// Returns the changed list on OK, nil on Cancel.
    static func run(_ hotlist: Hotlist, kernel: Kernel, currentDirectory: URL) -> Hotlist? {
        let controller = HotlistEditorWindowController(hotlist, kernel: kernel, currentDirectory: currentDirectory)
        let window = controller.dialog
        window.center()
        NSApplication.shared.runModal(for: window)
        window.orderOut(nil)
        return controller.result
    }

    /// The changed list after OK; nil before and after Cancel.
    var result: Hotlist? { accepted ? hotlist : nil }

    init(_ hotlist: Hotlist, kernel: Kernel, currentDirectory: URL) {
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
        buildContent(in: window)
        reload(selecting: hotlist.rows.first?.path)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        table.headerView = nil
        table.rowHeight = 18
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(toggleHidden)
        table.onKey = { [weak self] event in self?.handleKey(event) == true }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.widthAnchor.constraint(equalToConstant: 140).isActive = true
            return button
        }
        let add = [
            button("Add Item…", #selector(addItem)), button("Add Submenu…", #selector(addSubmenu)),
            button("Add Separator", #selector(addSeparator))
        ]
        entryButtons = [
            button("Delete Item", #selector(deleteEntry)), button("Change Title…", #selector(changeTitle)),
            button("Move Up", #selector(moveEntryUp)), button("Move Down", #selector(moveEntryDown))
        ]
        let buttons = NSStackView(views: add + entryButtons)
        buttons.orientation = .vertical
        buttons.alignment = .leading
        let top = NSStackView(views: [scroll, buttons])
        top.alignment = .top

        commandField.placeholderString = "cd /path/to/folder   (or the name of a command, e.g. cm_GoToRoot)"
        targetField.placeholderString = "optional: a path shown in the other panel at the same time"
        hideField.widthAnchor.constraint(equalToConstant: 30).isActive = true
        hideField.stringValue = hotlist.hideCharacter
        hideBox.state = hotlist.hidesMarked ? .on : .off
        hideBox.target = self
        hideBox.action = #selector(hidingChanged)
        for field in [commandField, targetField, hideField] { field.delegate = self }
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        let fields = NSGridView(views: [[label("Command:"), commandField], [label("Target path:"), targetField]])
        fields.column(at: 0).xPlacement = .trailing
        let hiding = NSStackView(views: [hideBox, hideField])
        let hint = NSTextField(
            labelWithString: "Double click a menu item to hide or show it. Shift+↑ and Shift+↓ move it."
        )
        hint.textColor = .secondaryLabelColor

        let ok = NSButton(title: "OK", target: self, action: #selector(accept))
        ok.keyEquivalent = "\r"
        let footer = NSStackView(views: [
            numberLabel, NSView(), NSButton(title: "Cancel", target: self, action: #selector(cancel)), ok
        ])
        numberLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [top, fields, hiding, hint, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        for part in [top, fields, footer] as [NSView] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        window.contentView = stack
    }

    // MARK: The list

    private var selectedPath: Hotlist.Path? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].path : nil
    }

    private func reload(selecting path: Hotlist.Path?) {
        rows = hotlist.rows
        table.reloadData()
        if let row = rows.firstIndex(where: { $0.path == path }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        showSelection()
    }

    private func showSelection() {
        let entry = selectedPath.flatMap(hotlist.entry(at:))
        let item = entry?.kind == .item ? entry : nil
        commandField.stringValue = item?.command ?? ""
        targetField.stringValue = item?.target ?? ""
        commandField.isEnabled = item != nil
        targetField.isEnabled = item != nil
        entryButtons.forEach { $0.isEnabled = entry != nil }
        entryButtons[1].isEnabled = entry != nil && entry?.kind != .separator
        numberLabel.stringValue = rows.isEmpty ? "" : "Entry \(table.selectedRow + 1) of \(rows.count)"
    }

    /// Where a new entry goes: right below the selected line, which is inside a submenu when
    /// that line is the submenu's title.
    private var insertionPath: Hotlist.Path {
        guard let path = selectedPath, let index = path.last, let entry = hotlist.entry(at: path) else {
            return [hotlist.entries.count]
        }
        return entry.kind == .submenu ? path + [0] : Array(path.dropLast()) + [index + 1]
    }

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

    @objc
    private func addSubmenu() {
        guard let title = kernel.interaction.prompt("Title of the new submenu:"), !title.isEmpty else {
            return
        }
        add(.submenu(title))
    }

    @objc
    private func addSeparator() {
        add(.separator)
    }

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

    @objc
    private func changeTitle() {
        guard let path = selectedPath, let entry = hotlist.entry(at: path), entry.kind != .separator,
            let title = kernel.interaction.prompt("New title:", value: entry.title), !title.isEmpty
        else { return }
        hotlist.update(at: path) { $0.title = title }
        reload(selecting: path)
    }

    @objc
    private func moveEntryUp() { move(-1) }
    @objc
    private func moveEntryDown() { move(1) }

    private func move(_ direction: Int) {
        guard let path = selectedPath else {
            return
        }
        reload(selecting: hotlist.move(at: path, by: direction))
    }

    @objc
    private func toggleHidden() {
        guard let path = selectedPath else {
            return
        }
        hotlist.toggleHideMark(at: path)
        reload(selecting: path)
    }

    @objc
    private func hidingChanged() {
        hotlist.hidesMarked = hideBox.state == .on
    }

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
    func controlTextDidChange(_ notification: Notification) {
        let field = notification.object as? NSTextField
        if field === hideField {
            // Any character but the dash, which already means separators and submenus.
            let character = String(hideField.stringValue.prefix(1))
            hotlist.hideCharacter = character == "-" ? "" : character
        } else if let path = selectedPath {
            // The command field, or else the target path's.
            hotlist.update(at: path) { entry in
                if field === commandField {
                    entry.command = commandField.stringValue
                } else {
                    entry.target = targetField.stringValue
                }
            }
            rows = hotlist.rows
        }
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
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

    /// A line of the editor's list: indented by its depth, submenus with a mark of their own.
    nonisolated static func title(of row: Hotlist.Row) -> String {
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

    func tableViewSelectionDidChange(_: Notification) {
        showSelection()
    }

    // MARK: Result

    @objc
    private func accept() {
        // A field that is still being edited hands in its text first.
        window?.makeFirstResponder(nil)
        accepted = true
        close()
    }

    @objc
    private func cancel() {
        close()
    }

    func windowWillClose(_: Notification) {
        // Only the loop this window runs in is ended: a stop without one would end whatever
        // loop the main thread runs.
        if NSApplication.shared.modalWindow === window { NSApplication.shared.stopModal() }
    }
}
