import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The "Synchronize directories" window (spec 09 › Window and workflow). It draws a
/// `SyncSession` and forwards clicks and keys to it; nothing here touches a file system.
/// Main thread only.
final class SyncWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let session: SyncSession
    private let kernel: Kernel

    private let setsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let leftField = NSTextField()
    private let rightField = NSTextField()
    private let maskField = NSTextField()
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let synchronizeButton = NSButton(title: "Synchronize…", target: nil, action: nil)
    private let subdirsBox = NSButton(checkboxWithTitle: "Subdirs", target: nil, action: nil)
    private let byContentBox = NSButton(checkboxWithTitle: "by content", target: nil, action: nil)
    private let ignoreDateBox = NSButton(checkboxWithTitle: "ignore date", target: nil, action: nil)
    private let asymmetricBox = NSButton(checkboxWithTitle: "Asymmetric", target: nil, action: nil)
    private let emptyDirectoriesBox = NSButton(checkboxWithTitle: "Empty directories", target: nil, action: nil)
    private let onlySelectedBox = NSButton(checkboxWithTitle: "Only selected (in main window)", target: nil, action: nil)
    private let oneHourBox = NSButton(checkboxWithTitle: "ignore 1 h difference", target: nil, action: nil)
    private let tolerancePopup = NSPopUpButton()
    private let offsetField = NSTextField()
    private var showButtons: [(button: NSButton, part: SyncShow)] = []
    private let indicatorLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let table = KeyTableView()
    private let rowMenu = NSMenu()

    private static let tolerances = [0, 2, 3]
    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("leftName", "Name", 210), ("leftSize", "Size", 90), ("leftDate", "Date", 140), ("action", "<=>", 44),
        ("rightDate", "Date", 140), ("rightSize", "Size", 90), ("rightName", "Name", 210),
    ]
    /// Dates in the short format with seconds (spec 09 › Result list).
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private final class KeyTableView: NSTableView {
        var onKey: ((NSEvent) -> Bool)?

        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }

        /// A right click on a row outside the selection moves the selection there first.
        override func menu(for event: NSEvent) -> NSMenu? {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            guard row >= 0 else { return nil }
            if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
            return super.menu(for: event)
        }
    }

    init(session: SyncSession) {
        self.session = session
        kernel = session.kernel
        let window = ToolWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Synchronize directories"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 380)
        window.center()
        super.init(window: window)
        window.delegate = self
        // Esc interrupts a running comparison; when idle it closes the window.
        window.onEscape = { [weak self] in
            guard let self, self.session.phase == .comparing else { return false }
            self.session.cancelComparison()
            return true
        }
        buildContent(in: window)
        session.onChange = { [weak self] in self?.refresh() }
        session.onRowsChange = { [weak self] rows in self?.refreshRows(rows) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the window with what the session holds now.
    func show() {
        pullControls()
        refresh()
        showWindow(nil)
        window?.makeFirstResponder(compareButton)
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        setsButton.addItem(withTitle: "★")
        setsButton.menu?.delegate = self
        setsButton.toolTip = "Saved directories and settings (F2)"
        maskField.placeholderString = "*.*  (exclude after |)"
        maskField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        offsetField.widthAnchor.constraint(equalToConstant: 36).isActive = true
        offsetField.toolTip = "Hours added to the dates of the right side (a server in another time zone)"
        tolerancePopup.addItems(withTitles: ["exact dates", "±2 s (FAT)", "±3 s"])
        for field in [leftField, rightField, maskField, offsetField] {
            field.target = self
            field.action = #selector(compareFromField)
        }
        compareButton.target = self
        compareButton.action = #selector(compareOrAbort)
        compareButton.keyEquivalent = "\r"
        synchronizeButton.target = self
        synchronizeButton.action = #selector(synchronize)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        for box in [subdirsBox, byContentBox, ignoreDateBox, asymmetricBox, emptyDirectoriesBox, onlySelectedBox, oneHourBox] {
            box.target = self
            box.action = #selector(optionChanged)
        }
        tolerancePopup.target = self
        tolerancePopup.action = #selector(optionChanged)

        let parts: [(String, SyncShow, String)] = [
            ("→", .copyToRight, "Files to copy to the right (Ctrl+Shift+L)"), ("=", .equal, "Equal files (Ctrl+Shift+E)"),
            ("≠", .notEqual, "Different files (Ctrl+Shift+N)"), ("←", .copyToLeft, "Files to copy to the left, or to delete on the right (Ctrl+Shift+R)"),
            ("duplicates", .duplicates, "Files on both sides (Ctrl+Shift+D)"), ("singles", .singles, "Files on one side only (Ctrl+Shift+S)"),
        ]
        showButtons = parts.map { title, part, tip in
            let button = NSButton(title: title, target: self, action: #selector(showChanged))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.toolTip = tip
            return (button, part)
        }

        func picker(_ action: Selector) -> NSButton {
            let button = NSButton(title: ">>", target: self, action: action)
            button.toolTip = "Choose a folder"
            return button
        }
        let paths = NSStackView(views: [setsButton, leftField, picker(#selector(pickLeft)), maskField, rightField, picker(#selector(pickRight))])
        leftField.widthAnchor.constraint(equalTo: rightField.widthAnchor).isActive = true
        let options = NSStackView(views: [compareButton, subdirsBox, byContentBox, ignoreDateBox, asymmetricBox, emptyDirectoriesBox,
                                          onlySelectedBox, NSView(), synchronizeButton, closeButton])
        let showRow = NSStackView(views: [NSTextField(labelWithString: "Show:")] + showButtons.map(\.button)
            + [indicatorLabel, NSView(), tolerancePopup, oneHourBox, NSTextField(labelWithString: "dT="), offsetField,
               NSTextField(labelWithString: "h")])
        indicatorLabel.textColor = .secondaryLabelColor
        indicatorLabel.lineBreakMode = .byTruncatingMiddle
        indicatorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (id, title, width) in SyncWindowController.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 36
            column.headerCell.alignment = id.hasSuffix("Size") ? .right : (id == "action" ? .center : .left)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.style = .plain
        table.allowsMultipleSelection = true
        table.floatsGroupRows = false
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        rowMenu.delegate = self
        table.menu = rowMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let footer = NSStackView(views: [statusLabel, NSView(), progressBar])

        let stack = NSStackView(views: [paths, options, showRow, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        for part in [paths, options, showRow, scroll, footer] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
    }

    // MARK: Controls and session

    /// Fills the controls from the session.
    private func pullControls() {
        leftField.stringValue = session.leftPath
        rightField.stringValue = session.rightPath
        let options = session.options
        maskField.stringValue = options.mask
        subdirsBox.state = options.subdirectories ? .on : .off
        byContentBox.state = options.byContent ? .on : .off
        ignoreDateBox.state = options.ignoreDate ? .on : .off
        asymmetricBox.state = options.asymmetric ? .on : .off
        emptyDirectoriesBox.state = options.emptyDirectories ? .on : .off
        oneHourBox.state = options.ignoreOneHourDifference ? .on : .off
        onlySelectedBox.state = session.onlySelected ? .on : .off
        onlySelectedBox.isEnabled = !session.selectedNames.isEmpty
        tolerancePopup.selectItem(at: SyncWindowController.tolerances.firstIndex(of: options.toleranceSeconds) ?? 2)
        offsetField.stringValue = String(options.timeOffsetHours)
        for (button, part) in showButtons { button.state = session.show.contains(part) ? .on : .off }
    }

    /// Takes what the controls say into the session.
    private func pushControls() {
        // A path that was typed into its field (not the one the window was opened with, nor
        // one a saved set brought) is the user's own choice of a server, if it names one.
        for (typed, known) in [(leftField.stringValue, session.leftPath), (rightField.stringValue, session.rightPath)] {
            kernel.userTyped(location: typed, proposal: known, relativeTo: session.base)
        }
        session.leftPath = leftField.stringValue
        session.rightPath = rightField.stringValue
        var options = session.options
        options.mask = maskField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "*.*" : maskField.stringValue
        options.subdirectories = subdirsBox.state == .on
        options.byContent = byContentBox.state == .on
        options.ignoreDate = ignoreDateBox.state == .on
        options.asymmetric = asymmetricBox.state == .on
        options.emptyDirectories = emptyDirectoriesBox.state == .on
        options.ignoreOneHourDifference = oneHourBox.state == .on
        options.toleranceSeconds = SyncWindowController.tolerances[max(0, min(2, tolerancePopup.indexOfSelectedItem))]
        options.timeOffsetHours = Int(offsetField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        session.options = options
        session.onlySelected = onlySelectedBox.state == .on
    }

    @objc private func optionChanged() {
        pushControls()
    }

    @objc private func showChanged() {
        session.show = SyncShow(showButtons.filter { $0.button.state == .on }.map(\.part))
    }

    private func toggleShow(_ part: SyncShow) {
        session.show.formSymmetricDifference(part)
        pullControls()
    }

    @objc private func compareFromField() {
        if session.phase != .comparing, session.phase != .synchronizing { compareOrAbort() }
    }

    @objc private func compareOrAbort() {
        if session.phase == .comparing {
            session.cancelComparison()
        } else if session.phase != .synchronizing {
            pushControls()
            session.compare()
        }
    }

    @objc private func synchronize() {
        session.synchronize()
    }

    @objc private func closeWindow() {
        close()
    }

    @objc private func pickLeft() { pickFolder(for: leftField) }
    @objc private func pickRight() { pickFolder(for: rightField) }

    private func pickFolder(for field: NSTextField) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { field.stringValue = url.path }
        }
    }

    /// Redraws everything that follows the session.
    private func refresh() {
        let selection = table.selectedRowIndexes
        let sameLength = table.numberOfRows == session.entries.count
        table.reloadData()
        if sameLength { table.selectRowIndexes(selection, byExtendingSelection: false) }
        statusLabel.stringValue = session.status
        compareButton.title = session.phase == .comparing ? "Abort" : "Compare"
        compareButton.isEnabled = session.phase != .synchronizing
        synchronizeButton.isEnabled = session.canSynchronize
        progressBar.isHidden = session.fraction == nil
        progressBar.doubleValue = session.fraction ?? 0
        updateIndicator()
    }

    /// Redraws just the rows whose action changed, and the Synchronize button.
    private func refreshRows(_ rows: [Int]) {
        let positions = IndexSet(rows.compactMap { session.positions.indices.contains($0) && session.positions[$0] >= 0 ? session.positions[$0] : nil })
        if !positions.isEmpty { table.reloadData(forRowIndexes: positions, columnIndexes: IndexSet(0..<table.numberOfColumns)) }
        synchronizeButton.isEnabled = session.canSynchronize
    }

    private func updateIndicator() {
        let position = table.selectedRow >= 0 ? table.selectedRow : max(0, table.rows(in: table.visibleRect).location)
        indicatorLabel.stringValue = session.groupIndicator(atEntry: position)
    }

    // MARK: Rows

    /// The session rows the commands act on: the selected ones.
    private var selectedRows: [Int] {
        table.selectedRowIndexes.compactMap { position in
            guard session.entries.indices.contains(position), case .row(let index) = session.entries[position] else { return nil }
            return index
        }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, session.entries.indices.contains(table.clickedRow), table.clickedColumn >= 0,
              table.tableColumns[table.clickedColumn].identifier.rawValue == "action",
              case .row(let index) = session.entries[table.clickedRow] else { return }
        session.cycle(row: index)
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedColumn < 0 || table.tableColumns[table.clickedColumn].identifier.rawValue != "action" else { return }
        session.compareContents(row: selectedRows.first)
    }

    private func jumpToHeader(forward: Bool) {
        guard let position = session.header(after: max(0, table.selectedRow), forward: forward) else { return }
        let target = min(position + 1, session.entries.count - 1)
        table.selectRowIndexes([target], byExtendingSelection: false)
        table.scrollRowToVisible(min(position + 12, session.entries.count - 1))
        table.scrollRowToVisible(position)
    }

    /// The keys of the result list (spec 09 › Keys and ini keys).
    private func handleKey(_ event: NSEvent) -> Bool {
        func key(_ character: String, _ modifiers: KeyModifiers = .control) -> Bool { Shortcut(.character(character), modifiers).matches(event) }
        // Only the keys that act on rows need them; a million selected rows are not mapped for every key.
        lazy var rows = selectedRows
        if Shortcut(.space).matches(event) || Shortcut(.space, .shift).matches(event) { session.toggle(rows: rows)
        } else if key("d") { session.markDefault(rows: rows)
        } else if key("m") { session.setAction(.none, rows: rows)
        } else if key("l") { session.setAction(.copyToRight, rows: rows)
        } else if key("r") { session.setAction(.copyToLeft, rows: rows)
        } else if key("w") { session.reverse(rows: rows)
        } else if key("l", [.control, .shift]) { toggleShow(.copyToRight)
        } else if key("e", [.control, .shift]) { toggleShow(.equal)
        } else if key("n", [.control, .shift]) { toggleShow(.notEqual)
        } else if key("r", [.control, .shift]) { toggleShow(.copyToLeft)
        } else if key("d", [.control, .shift]) { toggleShow(.duplicates)
        } else if key("s", [.control, .shift]) { toggleShow(.singles)
        } else if Shortcut.f(3, .control).matches(event) { session.compareContents(row: rows.first)
        } else if Shortcut.f(3).matches(event) { rows.first.map { session.view(.left, row: $0) }
        } else if Shortcut.f(3, .shift).matches(event) { rows.first.map { session.view(.right, row: $0) }
        } else if Shortcut.f(4).matches(event) { rows.first.map { session.view(.left, row: $0, command: .edit) }
        } else if Shortcut.f(4, .shift).matches(event) { rows.first.map { session.view(.right, row: $0, command: .edit) }
        } else if Shortcut.f(2).matches(event) { setsButton.performClick(nil)
        } else if Shortcut(.pageDown, .control).matches(event) { jumpToHeader(forward: true)
        } else if Shortcut(.pageUp, .control).matches(event) { jumpToHeader(forward: false)
        } else { return false }
        return true
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === rowMenu { buildRowMenu() } else { buildSetsMenu(menu) }
    }

    private func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .control, enabled: Bool = true,
                      _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, run: action)
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        return item
    }

    /// The context menu of the rows (spec 09 › Result list); it acts on the selected rows.
    private func buildRowMenu() {
        let rows = selectedRows
        let first = rows.first
        let hasLeft = first.flatMap { session.url(.left, row: $0) } != nil
        let hasRight = first.flatMap { session.url(.right, row: $0) } != nil
        rowMenu.autoenablesItems = false
        rowMenu.items = rows.isEmpty ? [] : [
            item("Mark for copying (default direction)", "d") { [session] in session.markDefault(rows: rows) },
            item("Unmark for copying (skip)", "m") { [session] in session.setAction(.none, rows: rows) },
            item("Mark for copying -> (left to right)", "l") { [session] in session.setAction(.copyToRight, rows: rows) },
            item("Mark for copying <- (right to left)", "r") { [session] in session.setAction(.copyToLeft, rows: rows) },
            item("Mark for copying in reverse direction", "w") { [session] in session.reverse(rows: rows) },
            .separator(),
            item("Select left file for comparison", enabled: hasLeft) { [session] in first.map { session.pick(.left, row: $0) } },
            item("Select right file for comparison", enabled: hasRight) { [session] in first.map { session.pick(.right, row: $0) } },
            item("Compare left & right", enabled: hasLeft || hasRight || (session.picked.left != nil && session.picked.right != nil)) { [session] in
                session.compareContents(row: first)
            },
            .separator(),
            item("View left", enabled: hasLeft) { [session] in first.map { session.view(.left, row: $0) } },
            item("View right", enabled: hasRight) { [session] in first.map { session.view(.right, row: $0) } },
            item("Edit left", enabled: hasLeft) { [session] in first.map { session.view(.left, row: $0, command: .edit) } },
            item("Edit right", enabled: hasRight) { [session] in first.map { session.view(.right, row: $0, command: .edit) } },
            .separator(),
            item("<- Delete left") { [session] in session.setAction(.deleteLeft, rows: rows) },
            item("-> Delete right") { [session] in session.setAction(.deleteRight, rows: rows) },
            item("Delete on both sides") { [session] in session.setAction(.deleteBoth, rows: rows) },
        ]
    }

    private func buildSetsMenu(_ menu: NSMenu) {
        let sets = session.savedSets
        var items = [NSMenuItem(title: "★", action: nil, keyEquivalent: ""),
                     item("Add current directories and settings to list…") { [weak self] in self?.saveSet() }]
        if !sets.isEmpty {
            items.append(.separator())
            items += sets.map { set in
                item(set.name) { [weak self] in
                    self?.session.loadSet(named: set.name)
                    self?.pullControls()
                }
            }
            let remove = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.items = sets.map { set in item(set.name) { [session] in session.removeSet(named: set.name) } }
            remove.submenu = submenu
            items += [.separator(), remove]
        }
        menu.items = items
    }

    private func saveSet() {
        pushControls()
        guard let name = kernel.ui.prompt("Name under which the directories and settings are saved:", value: "")?
            .trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        session.saveSet(named: name)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { session.entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = session.entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = session.entries[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "header"
        let identifier = NSUserInterfaceItemIdentifier("cell." + id)
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }()
        switch session.entries[row] {
        case .header(let directory):
            cell.stringValue = directory
            cell.textColor = .secondaryLabelColor
            cell.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        case .row(let index):
            let item = session.rows[index]
            cell.textColor = SyncWindowController.color(of: item)
            cell.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.alignment = id.hasSuffix("Size") ? .right : (id == "action" ? .center : .left)
            cell.stringValue = SyncWindowController.text(of: item, column: id)
        }
        return cell
    }

    static func text(of row: SyncRow, column: String) -> String {
        func size(_ item: FileItem?) -> String { item.map { row.isDirectory ? "<DIR>" : Format.bytes($0.size) } ?? "" }
        func date(_ item: FileItem?) -> String { item.map { dateFormatter.string(from: $0.modified) } ?? "" }
        func name(_ item: FileItem?) -> String { item.map { row.isDirectory ? "[\($0.name)]" : $0.name } ?? "" }
        switch column {
        case "leftName": return name(row.left)
        case "leftSize": return size(row.left)
        case "leftDate": return date(row.left)
        case "rightName": return name(row.right)
        case "rightSize": return size(row.right)
        case "rightDate": return date(row.right)
        default:
            if row.action != .none { return row.action.symbol }
            switch row.state {
            case .equal: return "="
            case .pending: return "?"
            case .excluded: return "⊘"
            default: return "≠"
            }
        }
    }

    /// The colour shows what the comparison proposed (spec 09 › Result list).
    static func color(of row: SyncRow) -> NSColor {
        switch row.defaultAction {
        case .copyToRight: return .systemGreen
        case .copyToLeft, .deleteRight: return .systemBlue
        default:
            switch row.state {
            case .equal: return .labelColor
            case .excluded, .pending: return .secondaryLabelColor
            default: return .systemRed
            }
        }
    }

    /// A click on a column header sorts by name, size or date of that side; again reverses.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let id = tableColumn.identifier.rawValue
        guard id != "action" else { return }
        let side: SyncSide = id.hasPrefix("left") ? .left : .right
        let key: SyncSortKey = id.hasSuffix("Size") ? .size : (id.hasSuffix("Date") ? .date : .name)
        let same = session.sort.key == key && session.sort.side == side
        session.sort = (key, side, same ? !session.sort.ascending : true)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateIndicator()
    }

    func windowWillClose(_ notification: Notification) {
        session.cancelComparison()
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, keyEquivalent: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runClosure), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runClosure() { run() }
}
