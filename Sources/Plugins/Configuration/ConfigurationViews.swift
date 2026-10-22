import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// A button that runs a closure.
final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(pressed)
        bezelStyle = .rounded
    }

    @objc private func pressed() { handler?() }
}

/// A stack whose parts fill it: across, every part is as wide (or as high) as the stack, and
/// along it the parts without a size of their own (lists, spacers) take the room that is left.
@MainActor
func filledStack(_ views: [NSView], vertical: Bool, spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.distribution = .fill
    stack.alignment = vertical ? .leading : .top
    stack.spacing = spacing
    for view in views {
        if vertical {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if view is NSScrollView || view is NSStackView {
            view.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
    }
    return stack
}

/// A view with a margin around it, as the content of a window.
@MainActor
func padded(_ view: NSView, by margin: CGFloat = 14) -> NSView {
    let holder = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: holder.topAnchor, constant: margin),
        view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: margin),
        view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -margin),
        view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -margin)
    ])
    return holder
}

/// Takes the room nothing else wants.
@MainActor
func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentHuggingPriority(.init(1), for: .vertical)
    return view
}

/// A list of text rows in columns, as the editors of the configuration windows use it.
///
/// Main thread only.
final class RowsTable: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private final class Table: NSTableView {
        var onReturn: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76, let onReturn {
                onReturn()
                return
            }
            super.keyDown(with: event)
        }
    }

    private let table = Table()
    private var rows: [[String]] = []
    /// A system symbol shown in front of each row; rows without one show none.
    private var symbols: [String?] = []
    var onSelect: () -> Void = {}
    /// A double click or Return on a row.
    var onActivate: (() -> Void)? {
        didSet { table.onReturn = { [weak self] in self?.onActivate?() } }
    }

    init(columns: [(title: String, width: CGFloat)]) {
        super.init(frame: .zero)
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        if columns.allSatisfy(\.title.isEmpty) { table.headerView = nil }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        documentView = table
        hasVerticalScroller = true
        borderType = .bezelBorder
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    var tableView: NSTableView { table }

    /// The selected row; nil when none is.
    var selectedRow: Int? {
        get { table.selectedRow >= 0 ? table.selectedRow : nil }
        set {
            if let row = newValue, rows.indices.contains(row) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    /// Shows other rows and keeps the selection on the same position where there still is one.
    func show(_ rows: [[String]], symbols: [String?] = [], selecting row: Int? = nil) {
        let selected = row ?? selectedRow
        self.rows = rows
        self.symbols = symbols
        table.reloadData()
        selectedRow = selected.map { min($0, rows.count - 1) }
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = tableColumn.flatMap { Int($0.identifier.rawValue) } ?? 0
        let label = NSTextField(labelWithString: rows[row].indices.contains(column) ? rows[row][column] : "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        var leading = cell.leadingAnchor
        if column == 0, symbols.indices.contains(row), let name = symbols[row] {
            let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20)
            ])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) { onSelect() }

    @objc private func doubleClicked() {
        if table.clickedRow >= 0 { onActivate?() }
    }
}

/// A window that shows a text: the keyboard help and the "what is where" page.
final class TextWindowController: NSWindowController {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))

    init(title: String) {
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.usesFindBar = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        window.contentView = scroll
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    /// Shows `text`; `present` puts the window on screen.
    func show(_ text: String, present: (NSWindowController) -> Void) {
        textView.string = text
        present(self)
        window?.makeFirstResponder(textView)
    }
}

/// Runs the entries of the Start menu after the menu was rebuilt while the program runs.
@MainActor
final class StartMenuTarget: NSObject, NSMenuItemValidation {
    private unowned let kernel: Kernel

    init(kernel: Kernel) {
        self.kernel = kernel
    }

    private func command(of item: NSMenuItem) -> CommandID? {
        (item.representedObject as? String).map(CommandID.init(rawValue:))
    }

    @objc func runEntry(_ sender: NSMenuItem) {
        if let id = command(of: sender) { kernel.commands.perform(id) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        command(of: menuItem).map(kernel.commands.isEnabled) ?? false
    }
}

/// Changes to the menu bar while the program runs.
///
/// The shell builds its menus once, from the registries; its items carry the name of their command,
/// which is all that is relied on here.
@MainActor
enum LiveMenus {
    private static let slotPrefix = "cm_UserMenu"

    /// The key as a menu shows it; nil for keys a menu cannot show.
    ///
    /// The same rule as the shell's.
    private static func menuEquivalent(_ key: Key) -> String? {
        // AppKit's characters of the special keys lie in one block of 16-bit code units.
        func special(_ value: Int) -> String { String(utf16CodeUnits: [UInt16(truncatingIfNeeded: value)], count: 1) }
        switch key {
        case .character(let character): return character
        case .function(let number): return special(NSF1FunctionKey + number - 1)
        case .returnKey: return "\r"
        case .tab: return "\t"
        case .backspace: return "\u{8}"
        case .forwardDelete: return special(NSDeleteFunctionKey)
        case .home: return special(NSHomeFunctionKey)
        case .end: return special(NSEndFunctionKey)
        case .pageUp: return special(NSPageUpFunctionKey)
        case .pageDown: return special(NSPageDownFunctionKey)
        case .leftArrow: return special(NSLeftArrowFunctionKey)
        case .rightArrow: return special(NSRightArrowFunctionKey)
        case .upArrow: return special(NSUpArrowFunctionKey)
        case .downArrow: return special(NSDownArrowFunctionKey)
        default: return nil
        }
    }

    /// Plain typing keys stay with text fields, so a menu owns only function keys and keys
    /// with Cmd, Ctrl or Option.
    private static func menuKey(_ shortcut: Shortcut) -> String? {
        guard let key = menuEquivalent(shortcut.key) else { return nil }
        if case .function = shortcut.key { return key }
        return shortcut.modifiers.isDisjoint(with: [.command, .control, .option]) ? nil : key
    }

    private static func flags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Shows the keys in force next to every menu item that stands for a command.
    static func refreshKeys(in menu: NSMenu, kernel: Kernel) {
        for item in menu.items {
            if let submenu = item.submenu { refreshKeys(in: submenu, kernel: kernel) }
            guard let name = item.representedObject as? String, kernel.commands[CommandID(rawValue: name)] != nil else {
                continue
            }
            let shortcut = kernel.keyBindings.shortcuts(for: CommandID(rawValue: name)).first { menuKey($0) != nil }
            item.keyEquivalent = shortcut.flatMap(menuKey) ?? ""
            item.keyEquivalentModifierMask = shortcut.map { flags($0.modifiers) } ?? []
        }
    }

    /// Replaces the user's entries of the Start menu by the current ones; the menu's fixed
    /// entries stay below them.
    ///
    /// Does nothing when the menu bar has no Start menu.
    static func rebuildStartMenu(in mainMenu: NSMenu, entries: [StartMenuEntry], target: StartMenuTarget) {
        guard let menu = mainMenu.items.first(where: { $0.submenu?.title == MenuID.start.title })?.submenu else {
            return
        }
        let fixed = menu.items.filter { item in
            guard let name = item.representedObject as? String else { return false }
            return !name.hasPrefix(slotPrefix)
        }
        menu.removeAllItems()
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            let item = NSMenuItem(
                title: DisplayText.oneLine(entry.title.replacingOccurrences(of: "&", with: ""), limit: 120),
                action: #selector(StartMenuTarget.runEntry(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = StartMenuEntry.commandID(at: index).rawValue
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == false, !fixed.isEmpty { menu.addItem(.separator()) }
        fixed.forEach(menu.addItem)
    }
}
