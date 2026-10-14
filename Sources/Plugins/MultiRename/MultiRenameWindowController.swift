import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The window of the Multi-Rename Tool (spec 09 › Window and scope). It only shows a
/// `MultiRenameSession` and passes on what the user does; everything it does is on the main
/// thread, and the session keeps the work off it.
final class MultiRenameWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate, NSComboBoxDelegate
{
    /// A window that offers its keys to the tool before the focused field sees them: F2, F5
    /// and F10 work wherever the cursor is.
    private final class Window: ToolWindow {
        var onKeyDown: ((NSEvent) -> Bool)?

        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, onKeyDown?(event) == true { return }
            super.sendEvent(event)
        }
    }

    private final class ListView: NSTableView {
        var onKey: ((NSEvent) -> Bool)?

        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }

    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    private let session: MultiRenameSession
    /// Called when the window has closed, so that its owner can let go of it.
    var onClose: (() -> Void)?
    /// What the histories and menus were last built from; they are built again only when it changes.
    private var shownRevision = -1
    private var shownGivenNames: Bool?

    private let nameMaskBox = NSComboBox()
    private let extensionField = NSTextField()
    private let searchBox = NSComboBox()
    private let replaceBox = NSComboBox()
    private let caseBox = NSButton(checkboxWithTitle: "^", target: nil, action: nil)
    private let onceBox = NSButton(checkboxWithTitle: "1x", target: nil, action: nil)
    private let extensionBox = NSButton(checkboxWithTitle: "[E]", target: nil, action: nil)
    private let regexBox = NSButton(checkboxWithTitle: "RegEx", target: nil, action: nil)
    private let substituteBox = NSButton(checkboxWithTitle: "Subst.", target: nil, action: nil)
    private let letterCasePopup = NSPopUpButton()
    private let startField = NSTextField()
    private let stepField = NSTextField()
    private let startStepper = NSStepper()
    private let stepStepper = NSStepper()
    private let digitsPopup = NSPopUpButton()
    private let settingsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let namesPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let table = ListView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let nextStepButton = NSButton(title: "↻ Next step (F5)", target: nil, action: nil)
    private let startButton = NSButton(title: "Start!", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let resultButton = NSButton(title: "Result list", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var maskOnlyButtons: [NSButton] = []

    private var sortColumn: String?
    private var sortAscending = true
    /// The saved settings chosen last; "Delete entry" deletes these.
    private var loadedName: String?
    private static let rowType = NSPasteboard.PasteboardType("afm.multirename.row")
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init(kernel: Kernel, session: MultiRenameSession) {
        self.kernel = kernel
        self.session = session
        let window = Window(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Multi-Rename Tool"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 420)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onKeyDown = { [weak self] event in self?.handleWindowKey(event) ?? false }
        buildContent(in: window)
        showSettings()
        update()
        session.onChange = { [weak self] in self?.update() }
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func box(_ title: String, _ rows: [NSView]) -> NSBox {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let box = NSBox()
        box.title = title
        box.contentView = stack
        box.contentViewMargins = NSSize(width: 8, height: 6)
        return box
    }

    private func button(_ title: String, _ action: Selector, tip: String = "") -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = tip.isEmpty ? nil : tip
        return button
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 6
        return stack
    }

    private func buildContent(in window: NSWindow) {
        for combo in [nameMaskBox, searchBox, replaceBox] {
            combo.delegate = self
            combo.completes = false
            combo.numberOfVisibleItems = 12
        }
        for field in [extensionField, startField, stepField] { field.delegate = self }
        nameMaskBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        extensionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        for field in [startField, stepField] { field.widthAnchor.constraint(equalToConstant: 64).isActive = true }

        let nameButtons = [
            button("[N] Name", #selector(insertName)), button("[N#-#] Range", #selector(insertNameRange)),
            button("[C] Counter", #selector(insertNameCounter)), button("[YMD] Date", #selector(insertDate)),
            button("[hms] Time", #selector(insertTime)),
            button("+", #selector(showMoreFields(_:)), tip: "More fields"),
            button("#", #selector(showRangeFields(_:)), tip: "Ranges of other fields")
        ]
        let extensionButtons = [
            button("[E] Ext.", #selector(insertExtension)), button("[E#-#] Range", #selector(insertExtensionRange)),
            button("[C] Counter", #selector(insertExtensionCounter))
        ]
        maskOnlyButtons = nameButtons + extensionButtons
        let nameBox = box(
            "Rename mask: file name", [nameMaskBox, row(Array(nameButtons[0..<4])), row(Array(nameButtons[4...]))])
        let extensionGroup = box(
            "Extension", [extensionField, row(Array(extensionButtons[0..<2])), extensionButtons[2]])

        for (check, tip) in [
            (caseBox, "Respect upper/lowercase"), (onceBox, "Replace only the first occurrence (key 1 in the list)"),
            (extensionBox, "Also search the extension"), (regexBox, "Search for is a regular expression"),
            (substituteBox, "Replace the whole name by Replace with")
        ] {
            check.target = self
            check.action = #selector(optionChanged)
            check.toolTip = tip
        }
        LetterCase.allCases.forEach { letterCasePopup.addItem(withTitle: $0.title) }
        letterCasePopup.target = self
        letterCasePopup.action = #selector(optionChanged)
        let searchGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Search for:"), searchBox],
            [NSTextField(labelWithString: "Replace with:"), replaceBox]
        ])
        searchGrid.column(at: 0).xPlacement = .trailing
        searchGrid.rowSpacing = 6
        let searchGroup = box(
            "Search & Replace",
            [
                searchGrid, row([caseBox, onceBox, extensionBox, regexBox, substituteBox]),
                row([NSTextField(labelWithString: "Upper/lowercase:"), letterCasePopup])
            ])

        for stepper in [startStepper, stepStepper] {
            stepper.minValue = -1_000_000_000
            stepper.maxValue = 1_000_000_000
            stepper.target = self
            stepper.action = #selector(stepperChanged(_:))
        }
        digitsPopup.addItems(withTitles: (1...10).map(String.init) + ["a (automatic)"])
        digitsPopup.target = self
        digitsPopup.action = #selector(optionChanged)
        let counterGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Start at:"), row([startField, startStepper])],
            [NSTextField(labelWithString: "Step by:"), row([stepField, stepStepper])],
            [NSTextField(labelWithString: "Digits:"), digitsPopup]
        ])
        counterGrid.column(at: 0).xPlacement = .trailing
        counterGrid.rowSpacing = 6
        let counterGroup = box("Define counter [C]", [counterGrid])

        let top = NSStackView(views: [nameBox, extensionGroup, searchGroup, counterGroup])
        top.alignment = .top
        top.spacing = 8
        nameBox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        settingsPopup.target = self
        settingsPopup.action = #selector(settingsChosen(_:))
        namesPopup.target = self
        namesPopup.action = #selector(namesChosen(_:))
        let tools = row([NSView(), namesPopup, settingsPopup])

        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("old", "Old name", 190), ("ext", "Ext.", 50), ("new", "New name", 250),
            ("size", "Size", 90), ("date", "Date", 150), ("location", "Location", 220)
        ]
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.registerForDraggedTypes([Self.rowType])
        table.onKey = { [weak self] event in self?.handleListKey(event) ?? false }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (control, action) in [
            (nextStepButton, #selector(nextStep)), (startButton, #selector(start)), (undoButton, #selector(undo)),
            (resultButton, #selector(showResultList)), (closeButton, #selector(closeWindow))
        ] {
            control.target = self
            control.action = action
        }
        let footer = row([statusLabel, NSView(), nextStepButton, startButton, undoButton, resultButton, closeButton])

        let stack = NSStackView(views: [top, tools, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for part in [top, tools, scroll, footer] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
        window.initialFirstResponder = nameMaskBox
    }

    // MARK: Fields and settings

    /// Puts the session's settings into the fields.
    private func showSettings() {
        let settings = session.settings
        nameMaskBox.stringValue = settings.nameMask
        extensionField.stringValue = settings.extensionMask
        searchBox.stringValue = settings.search
        replaceBox.stringValue = settings.replacement
        caseBox.state = settings.caseSensitive ? .on : .off
        onceBox.state = settings.firstOnly ? .on : .off
        extensionBox.state = settings.searchesExtension ? .on : .off
        regexBox.state = settings.regularExpression ? .on : .off
        substituteBox.state = settings.substitute ? .on : .off
        letterCasePopup.selectItem(at: settings.letterCase.rawValue)
        startField.stringValue = String(settings.counter.start)
        stepField.stringValue = String(settings.counter.step)
        startStepper.integerValue = settings.counter.start
        stepStepper.integerValue = settings.counter.step
        digitsPopup.selectItem(at: settings.counter.digits == 0 ? 10 : min(max(settings.counter.digits, 1), 10) - 1)
    }

    private func readFields() -> RenameSettings {
        var settings = RenameSettings()
        settings.nameMask = nameMaskBox.stringValue
        settings.extensionMask = extensionField.stringValue
        settings.search = searchBox.stringValue
        settings.replacement = replaceBox.stringValue
        settings.caseSensitive = caseBox.state == .on
        settings.firstOnly = onceBox.state == .on
        settings.searchesExtension = extensionBox.state == .on
        settings.regularExpression = regexBox.state == .on
        settings.substitute = substituteBox.state == .on
        settings.letterCase = LetterCase(rawValue: letterCasePopup.indexOfSelectedItem) ?? .unchanged
        settings.counter = CounterDefinition(
            start: Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1,
            step: Int(stepField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1,
            digits: digitsPopup.indexOfSelectedItem == 10 ? 0 : digitsPopup.indexOfSelectedItem + 1)
        return settings
    }

    /// Every change to a field shows in the preview at once.
    private func fieldsChanged() {
        session.settings = readFields()
        update()
    }

    func controlTextDidChange(_: Notification) {
        fieldsChanged()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The box holds the chosen text only after this notification.
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0,
            let text = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String
        else { return }
        combo.stringValue = text
        fieldsChanged()
    }

    @objc private func optionChanged() {
        fieldsChanged()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        (sender === startStepper ? startField : stepField).stringValue = String(sender.integerValue)
        fieldsChanged()
    }

    /// Brings buttons, menus, status line and list in line with the session.
    private func update() {
        if session.settings != readFields() { showSettings() }
        let usesMasks = session.givenNames == nil
        maskOnlyButtons.forEach { $0.isEnabled = usesMasks }
        nameMaskBox.isEnabled = usesMasks
        extensionField.isEnabled = usesMasks
        substituteBox.isEnabled = regexBox.state == .on
        startButton.isEnabled = !session.isBusy && session.rowCount > 0
        nextStepButton.isEnabled = !session.isBusy && session.rowCount > 0
        undoButton.isEnabled = session.canUndo
        resultButton.isEnabled = session.hasResultList
        let revision = session.store.revision
        let hasGivenNames = session.givenNames != nil
        if revision != shownRevision || hasGivenNames != shownGivenNames {
            (shownRevision, shownGivenNames) = (revision, hasGivenNames)
            reloadHistories()
            rebuildMenus()
        }

        let counts = session.counts
        if let problem = session.problem {
            statusLabel.stringValue = Self.describe(problem)
            statusLabel.textColor = .systemRed
        } else if counts.conflicts > 0 || counts.errors > 0 {
            statusLabel.stringValue = [
                counts.conflicts > 0 ? "\(counts.conflicts) name conflict(s)" : nil,
                counts.errors > 0 ? "\(counts.errors) name(s) cannot be used" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue =
                usesMasks
                ? "Please press 'Start!' to start renaming!"
                : "The names come from a list. Please press 'Start!' to start renaming!"
            statusLabel.textColor = .labelColor
        }
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection.filteredIndexSet { $0 < session.rowCount }, byExtendingSelection: false)
    }

    private static func describe(_ problem: any Error) -> String {
        switch problem {
        case RenameMaskError.invalidPlaceholder(let text): return "Invalid placeholder: \(text)"
        case RenameMaskError.contentPluginsUnavailable: return "Content-plugin fields [=…] are not available."
        case SearchReplace.Problem.invalidExpression(let text): return "Invalid regular expression: \(text)"

        case SearchReplace.Problem.tooSlow(let text):
            return "The regular expression takes too long for these names: \(text)"

        default: return "The rename mask is invalid."
        }
    }

    private func reloadHistories() {
        for (combo, history) in [
            (nameMaskBox, RenameStore.History.nameMask), (searchBox, .search), (replaceBox, .replacement)
        ] {
            let entries = session.store.history(history)
            if (combo.objectValues as? [String]) != entries {
                combo.removeAllItems()
                combo.addItems(withObjectValues: entries)
            }
        }
    }

    private func rebuildMenus() {
        func fill(_ popup: NSPopUpButton, _ title: String, _ items: [(String, String, Bool)]) {
            popup.removeAllItems()
            popup.addItem(withTitle: title)
            for (caption, tag, enabled) in items {
                if caption.isEmpty {
                    popup.menu?.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
                item.representedObject = tag
                item.isEnabled = enabled
                popup.menu?.addItem(item)
            }
            popup.autoenablesItems = false
        }
        let saved = session.store.savedNames
        fill(
            settingsPopup, "F2 Load/save settings",
            [
                ("<default>", "default", true), ("Save settings…", "save", true),
                ("Delete entry…", "delete", !saved.isEmpty), ("", "", false)
            ]
                + saved.map { ($0, "load:" + $0, true) })
        fill(
            namesPopup, "F10 Names",
            [
                ("Load names from file…", "load", true), ("Edit names…", "edit", true),
                ("Use the rename masks again", "masks", session.givenNames != nil)
            ])
    }

    // MARK: Inserting placeholders

    /// Puts a placeholder at the cursor of a mask field, in place of what is selected there.
    private func insert(_ text: String, into field: NSTextField) {
        if let editor = field.currentEditor() {
            editor.replaceCharacters(in: editor.selectedRange, with: text)
        } else {
            field.stringValue += text
        }
        fieldsChanged()
    }

    @objc private func insertName() { insert("[N]", into: nameMaskBox) }
    @objc private func insertNameCounter() { insert("[C]", into: nameMaskBox) }
    @objc private func insertDate() { insert("[YMD]", into: nameMaskBox) }
    @objc private func insertTime() { insert("[hms]", into: nameMaskBox) }
    @objc private func insertExtension() { insert("[E]", into: extensionField) }
    @objc private func insertExtensionCounter() { insert("[C]", into: extensionField) }
    @objc private func insertNameRange() { insertRange(of: "N", into: nameMaskBox) }
    @objc private func insertExtensionRange() { insertRange(of: "E", into: extensionField) }

    private static let moreFields: [(String, String)] = [
        ("[P]", "Parent folder"), ("[G]", "Grandparent folder"), ("[A]", "Name with extension"), ("[E]", "Extension"),
        ("[d]", "Date (regional format)"), ("[t]", "Time (regional format)"), ("[S]", "Size"),
        ("[T4]", "From here on: date taken (pictures) instead of date changed"),
        ("[U]", "All characters after this position in uppercase"),
        ("[L]", "All characters after this position in lowercase"),
        ("[F]", "First letter of each word uppercase after this position"),
        ("[f]", "First letter of each word uppercase after this position (English in Titles)"),
        ("[n]", "All characters after this position again as in original name"), ("[%USER%]", "User name"),
        ("[[]", "Square bracket: open"), ("[]]", "Square bracket: close"), ("[X]", "Clipboard text"),
        ("[c]", "Number of files in the list"),
        ("[I]", "Folders only (on/off): The name [N] includes the extension, [E] is not used")
    ]

    private static let rangeFields: [(String, String)] = [
        ("", "Full path+name"), ("P", "Parent folder"), ("G", "Grandparent folder"), ("A", "Name with extension"),
        ("E", "Extension"), ("X", "Clipboard text")
    ]

    @objc private func showMoreFields(_ sender: NSButton) {
        let menu = NSMenu()
        for (code, label) in Self.moreFields {
            let item = NSMenuItem(title: "\(code)  \(label)", action: #selector(insertFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func showRangeFields(_ sender: NSButton) {
        let menu = NSMenu()
        for (letter, label) in Self.rangeFields {
            let item = NSMenuItem(
                title: "[\(letter)#-#]  \(label)", action: #selector(insertRangeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = letter
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func insertFromMenu(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { insert(code, into: nameMaskBox) }
    }

    @objc private func insertRangeFromMenu(_ sender: NSMenuItem) {
        if let letter = sender.representedObject as? String { insertRange(of: letter, into: nameMaskBox) }
    }

    /// The range picker "Select the characters to insert" (spec 09 › Mask fields, insert
    /// buttons and menus), as a form: positions are typed instead of marked with the mouse.
    private func insertRange(of letter: String, into field: NSTextField) {
        let sample =
            (session.rowCount > 0 ? session.row(at: 0) : nil).map { row -> String in
                let parts = row.entry.item.isFolder ? (row.entry.name, "") : FileItem.split(row.entry.name)
                return letter == "N" ? parts.0 : letter == "E" ? parts.1 : row.entry.name
            } ?? ""
        let fields: [FormField] = [
            .text("first", "First character:", "1"), .text("last", "Last character (empty = to the end):", ""),
            .checkbox("firstFromEnd", "Measure first character from the end"),
            .checkbox("lastFromEnd", "Measure last character from the end"),
            .checkbox("length", "Use [first,length] instead of [first-last]")
        ]
        guard
            let answer = kernel.ui.form(
                "Select the characters to insert:", detail: sample, fields: fields, buttons: ["OK"]),
            let first = Int(answer.text("first").trimmingCharacters(in: .whitespaces)), first > 0
        else { return }
        var range = (answer.flag("firstFromEnd") ? "-" : "") + String(first)
        if let last = Int(answer.text("last").trimmingCharacters(in: .whitespaces)), last > 0 {
            range += answer.flag("length") ? ",\(last)" : "-" + (answer.flag("lastFromEnd") ? "-" : "") + String(last)
        } else {
            range += "-"
        }
        insert("[\(letter)\(range)]", into: field)
    }

    // MARK: Menus

    @objc private func settingsChosen(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.representedObject as? String else { return }
        switch tag {
        case "default":
            loadedName = nil
            session.settings = .unchanged

        case "save":
            if let name = kernel.ui.prompt("Save settings", value: loadedName ?? "", detail: "Name of the settings:") {
                session.save(as: name)
                loadedName = name.trimmingCharacters(in: .whitespaces)
            }

        case "delete":
            let names = session.store.savedNames
            guard
                let row = kernel.ui.pickRow(
                    "Delete entry", rows: names, selected: loadedName.flatMap(names.firstIndex(of:)) ?? 0,
                    button: "Delete")
            else { return }
            session.deleteSaved(names[row])
            if loadedName == names[row] { loadedName = nil }

        default:
            let name = String(tag.dropFirst("load:".count))
            if session.load(name) { loadedName = name }
        }
        update()
    }

    @objc private func namesChosen(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.representedObject as? String else { return }
        switch tag {
        case "load":
            let panel = NSOpenPanel()
            panel.message = "Load names from file: one name per line, in the order of the list"
            panel.allowsMultipleSelection = false
            guard let window else { return }
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url { self?.session.loadNames(from: url) }
            }

        case "edit": session.editNames()
        default: session.clearGivenNames()
        }
    }

    // MARK: Actions

    @objc private func nextStep() {
        session.nextStep()
    }

    @objc private func start() {
        guard !session.isBusy, window?.makeFirstResponder(nil) != false else { return }
        session.settings = readFields()
        session.start { [weak self] _ in
            self?.update()
        }
        update()
    }

    @objc private func undo() {
        session.undo()
    }

    @objc private func showResultList() {
        session.showResultList()
    }

    @objc private func closeWindow() {
        close()
    }

    /// F2, F5 and F10 (spec 09 › Keys), and Shift+Del to drop an entry from a field's history.
    private func handleWindowKey(_ event: NSEvent) -> Bool {
        if Shortcut.f(2).matches(event) {
            settingsPopup.performClick(nil)
        } else if Shortcut.f(5).matches(event) {
            nextStep()
        } else if Shortcut.f(10).matches(event) {
            namesPopup.performClick(nil)
        } else if Shortcut(.forwardDelete, .shift).matches(event) || Shortcut(.backspace, .shift).matches(event),
            let editor = window?.firstResponder as? NSText, let combo = editor.delegate as? NSComboBox
        {
            let histories: [(NSComboBox, RenameStore.History)] = [
                (nameMaskBox, .nameMask), (searchBox, .search), (replaceBox, .replacement)
            ]
            guard let history = histories.first(where: { $0.0 === combo })?.1,
                session.store.history(history).contains(combo.stringValue)
            else { return false }
            session.store.forget(combo.stringValue, in: history)
            reloadHistories()
        } else {
            return false
        }
        return true
    }

    /// Shift+Up/Down move the marked items, Del takes them out of the list, 1 toggles "1x".
    private func handleListKey(_ event: NSEvent) -> Bool {
        let selection = table.selectedRowIndexes
        if Shortcut(.up, .shift).matches(event) || Shortcut(.down, .shift).matches(event) {
            let moved = session.move(selection, by: Shortcut(.up, .shift).matches(event) ? -1 : 1)
            table.selectRowIndexes(moved, byExtendingSelection: false)
            if let first = moved.first { table.scrollRowToVisible(first) }
        } else if Shortcut(.forwardDelete).matches(event) || Shortcut(.backspace).matches(event) {
            guard !selection.isEmpty else { return true }
            session.remove(selection)
            let next = min(selection.first ?? 0, session.rowCount - 1)
            if next >= 0 { table.selectRowIndexes([next], byExtendingSelection: false) }
        } else if Shortcut(.character("1")).matches(event) {
            onceBox.state = onceBox.state == .on ? .off : .on
            fieldsChanged()
        } else {
            return false
        }
        return true
    }

    // MARK: The list

    func numberOfRows(in _: NSTableView) -> Int { session.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier, row >= 0, row < session.rowCount else { return nil }
        let cell =
            tableView.makeView(withIdentifier: column, owner: nil) as? NSTextField
            ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = column
                label.lineBreakMode = .byTruncatingMiddle
                return label
            }()
        let shown = session.row(at: row)
        let entry = shown.entry
        let status = shown.status
        let parts = entry.item.isFolder ? (base: entry.name, ext: "") : FileItem.split(entry.name)
        cell.textColor = .labelColor
        cell.alignment = .left
        cell.toolTip = nil
        switch column.rawValue {
        case "old": cell.stringValue = parts.base
        case "ext": cell.stringValue = parts.ext

        case "new":
            cell.stringValue = shown.newName ?? RenameEngine.errorText
            switch status {
            case .unchanged: cell.textColor = .secondaryLabelColor
            case .ready: break
            case .error: cell.textColor = .systemRed
            case .invalid(let reason): (cell.textColor, cell.toolTip) = (.systemRed, reason)

            case .duplicate:
                (cell.textColor, cell.toolTip) = (.systemRed, "Another file in the list gets the same name.")

            case .exists: (cell.textColor, cell.toolTip) = (.systemRed, "A file with this name already exists.")
            }

        case "size":
            cell.stringValue = entry.item.isFolder ? "<DIR>" : Format.bytes(entry.item.size)
            cell.alignment = .right

        case "date": cell.stringValue = Self.dateFormatter.string(from: entry.item.modified)
        default: cell.stringValue = kernel.fileSystems.displayPath(entry.directory) + "/"
        }
        return cell
    }

    /// A click on a header sorts by that column; a second click turns the order.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let keys: [String: MultiRenameSession.SortKey] = ["old": .name, "ext": .ext, "size": .size, "date": .date]
        guard let key = keys[tableColumn.identifier.rawValue] else { return }
        sortAscending = sortColumn == tableColumn.identifier.rawValue ? !sortAscending : true
        sortColumn = tableColumn.identifier.rawValue
        for column in tableView.tableColumns { tableView.setIndicatorImage(nil, in: column) }
        tableView.setIndicatorImage(
            NSImage(named: sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"), in: tableColumn)
        session.sort(by: key, ascending: sortAscending)
    }

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> any NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow _: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        (info.draggingSource as? NSTableView) === table && dropOperation == .above ? .move : []
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: Self.rowType).flatMap(Int.init)
        }
        guard !rows.isEmpty else { return false }
        // A reordered list is no longer sorted by any column.
        for column in tableView.tableColumns { tableView.setIndicatorImage(nil, in: column) }
        sortColumn = nil
        let moved = session.move(IndexSet(rows), to: row)
        table.selectRowIndexes(moved, byExtendingSelection: false)
        return true
    }

    func windowWillClose(_: Notification) {
        // The preview under way, and one that waits out the pause, are not wanted any more.
        session.close()
        onClose?()
    }
}
