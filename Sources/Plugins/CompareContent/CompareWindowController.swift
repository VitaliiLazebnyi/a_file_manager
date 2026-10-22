import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The "Compare contents" window (spec 09 › Compare by content › Window): two panes that
/// scroll and select together, one row per line of the comparison.
///
/// It draws a `CompareSession` and forwards clicks and keys to it; nothing here reads a file. Main
/// thread only.
final class CompareWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let session: CompareSession
    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    private let settings: any SettingsStore
    private let onClose: (CompareWindowController) -> Void
    private let effects: CompareWindowEffects
    /// The window, which the controller has from its start to its end.
    private let toolWindow: ToolWindow

    private let leftField = NSTextField()
    private let rightField = NSTextField()
    private let searchField = NSSearchField()
    private let binaryBox = NSButton(checkboxWithTitle: "Binary", target: nil, action: nil)
    private let bytesPopup = NSPopUpButton()
    private let caseBox = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)
    private let spacesBox = NSButton(checkboxWithTitle: "Ignore repeated spaces", target: nil, action: nil)
    private let endingsBox = NSButton(checkboxWithTitle: "Ignore line-end differences", target: nil, action: nil)
    private let verticalBox = NSButton(checkboxWithTitle: "Above each other", target: nil, action: nil)
    private let editBox = NSButton(checkboxWithTitle: "Edit mode", target: nil, action: nil)
    private var editButtons: [NSButton] = []
    private var differenceButtons: [NSButton] = []
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private let leftTable = PaneTableView()
    private let rightTable = PaneTableView()
    private var font: NSFont
    private var isMirroring = false
    private var jumpsToFirstDifference = true
    /// The lines marked for "Resync comparison from here", as rows.
    private var resyncMarks: (left: Int?, right: Int?) = (nil, nil)
    private var base = FileManager.default.homeDirectoryForCurrentUser

    private final class PaneTableView: NSTableView {
        var onKey: ((NSEvent) -> Bool)?

        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }

    /// Draws the background that tells what kind of line a row is.
    private final class DiffRowView: NSTableRowView {
        var fill: NSColor? { didSet { needsDisplay = true } }

        override func drawBackground(in dirtyRect: NSRect) {
            super.drawBackground(in: dirtyRect)
            guard let fill else {
                return
            }
            fill.setFill()
            bounds.intersection(dirtyRect).fill(using: .sourceOver)
        }
    }

    init(
        session: CompareSession,
        effects: CompareWindowEffects,
        onClose: @escaping (CompareWindowController) -> Void
    ) {
        self.session = session
        self.effects = effects
        self.onClose = onClose
        kernel = session.kernel
        settings = kernel.settings.scoped(to: CompareSettingsKey.scope)
        let size = CGFloat(Double(settings.text(CompareSettingsKey.fontSize, default: "12")) ?? 12)
        font =
            NSFont(name: settings.text(CompareSettingsKey.fontName, default: ""), size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compare contents"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 360)
        window.center()
        toolWindow = window
        super.init(window: window)
        window.delegate = self
        // Esc interrupts a running comparison; when idle it closes the window.
        window.onEscape = { [weak self] in self?.stopsComparison() == true }
        buildContent(in: window)
        session.onChange = { [weak self] in self?.refresh() }
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    /// Esc: stops a comparison that runs, and says so; false when none runs (Esc then closes the window).
    func stopsComparison() -> Bool {
        guard session.phase == .working else {
            return false
        }
        session.cancel()
        return true
    }

    func show() {
        if let url = session.leftURL ?? session.rightURL { base = url.deletingLastPathComponent() }
        pullControls()
        refresh()
        effects.present(self)
        window?.makeFirstResponder(leftTable)
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        func button(_ title: String, _ action: Selector, tip: String = "") -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.toolTip = tip
            return button
        }
        for field in [leftField, rightField] {
            field.target = self
            field.action = #selector(compare)
            field.lineBreakMode = .byTruncatingHead
        }
        let paths = NSStackView(views: [
            leftField, button(">>", #selector(pickLeft), tip: "Choose the left file"),
            rightField, button(">>", #selector(pickRight), tip: "Choose the right file")
        ])
        leftField.widthAnchor.constraint(equalTo: rightField.widthAnchor).isActive = true

        differenceButtons = [
            button("Next difference", #selector(nextDifference), tip: "Option+Down"),
            button("Previous difference", #selector(previousDifference), tip: "Option+Up")
        ]
        searchField.placeholderString = "Search in both files"
        searchField.target = self
        searchField.action = #selector(searchNext)
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        bytesPopup.addItems(withTitles: CompareSettingsKey.bytesPerLineChoices.map { "\($0) bytes" })
        let first = NSStackView(
            views: [button("Compare", #selector(compare))] + differenceButtons
                + [button("Font…", #selector(chooseFont)), searchField, NSView(), binaryBox, bytesPopup, verticalBox]
        )

        editButtons = [
            button(
                "Copy ->",
                #selector(copyToRight),
                tip: "Copy the difference or the selected lines to the right (Option+Right)"
            ),
            button(
                "Copy <-",
                #selector(copyToLeft),
                tip: "Copy the difference or the selected lines to the left (Option+Left)"
            ),
            button("Undo", #selector(undoEdit))
        ]
        saveButton.target = self
        saveButton.action = #selector(save)
        let resync = button(
            "Resync",
            #selector(markResync),
            tip:
                "Mark the selected line of the pane that has the focus; with a line marked on each side, the two are taken to belong together"
        )
        let second = NSStackView(
            views: [editBox] + editButtons + [
                saveButton, resync, button("Swap", #selector(swapSides), tip: "Swap panels (Ctrl+U)"),
                NSView(), caseBox, spacesBox, endingsBox
            ]
        )
        for box in [binaryBox, caseBox, spacesBox, endingsBox, verticalBox, editBox] {
            box.target = self
            box.action = #selector(optionChanged(_:))
        }
        bytesPopup.target = self
        bytesPopup.action = #selector(optionChanged(_:))

        split.isVertical = !settings.flag(CompareSettingsKey.vertical, default: false)
        split.dividerStyle = .thin
        for table in [leftTable, rightTable] { split.addArrangedSubview(makePane(table)) }

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [paths, first, second, split, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        for part in [paths, first, second, split, statusLabel] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
    }

    private func makePane(_ table: PaneTableView) -> NSScrollView {
        let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("number"))
        number.width = 70
        let text = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        text.width = 600
        table.addTableColumn(number)
        table.addTableColumn(text)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.menu = makeMenu()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        return scroll
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        add("Copy selection to clipboard", #selector(copySelection))
        add("Mark line for resync", #selector(markResync))
        add("Forget resync", #selector(clearResync))
        add("Swap Panels", #selector(swapSides))
        return menu
    }

    // MARK: Controls and session

    private func pullControls() {
        leftField.stringValue = session.displayPath(.left)
        rightField.stringValue = session.displayPath(.right)
        binaryBox.state = session.forceBinary ? .on : .off
        bytesPopup.selectItem(at: CompareSettingsKey.bytesPerLineChoices.firstIndex(of: session.bytesPerLine) ?? 1)
        caseBox.state = session.options.ignoreCase ? .on : .off
        spacesBox.state = session.options.ignoreRepeatedSpaces ? .on : .off
        endingsBox.state = session.options.ignoreLineEndings ? .on : .off
        verticalBox.state = split.isVertical ? .off : .on
        editBox.state = session.isEditing ? .on : .off
    }

    @objc
    private func optionChanged(_ sender: NSControl) {
        if sender === verticalBox {
            split.isVertical = verticalBox.state != .on
            settings.set(verticalBox.state == .on, forKey: CompareSettingsKey.vertical)
            split.adjustSubviews()
        } else if sender === editBox {
            session.setEditing(editBox.state == .on)
            pullControls()
        } else if sender === binaryBox {
            // Text and hex views are built from the files, so the files are read again.
            whenChangesAreSettled { [self] in
                session.forceBinary = binaryBox.state == .on
                jumpsToFirstDifference = true
                session.compare()
            }
            pullControls()
        } else {
            session.options = DiffOptions(
                ignoreCase: caseBox.state == .on,
                ignoreRepeatedSpaces: spacesBox.state == .on,
                ignoreLineEndings: endingsBox.state == .on
            )
            session.bytesPerLine =
                CompareSettingsKey.bytesPerLineChoices[max(0, min(3, bytesPopup.indexOfSelectedItem))]
            session.optionsChanged()
        }
    }

    /// Runs `action` unless there are unsaved changes the user wants to keep working on
    /// (spec 09 › Edit mode and saving: closing or re-comparing asks).
    private func whenChangesAreSettled(_ action: @escaping () -> Void) {
        guard session.hasUnsavedChanges else {
            action()
            return
        }
        let choice = kernel.interaction.pick(
            "Save the changes?",
            detail: "The compared files were edited.",
            [("Save", 0), ("Don't Save", 1), ("Cancel", 2)],
            fallback: 2,
            style: .warning
        )
        if choice == 0 {
            session.save { saved in if saved { action() } }
        } else if choice == 1 {
            action()
        }
    }

    @objc
    private func compare() {
        whenChangesAreSettled { [self] in
            let fileSystems = kernel.fileSystems
            @MainActor
            func location(_ field: NSTextField) -> URL? {
                let text = field.stringValue.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : fileSystems.location(from: text, relativeTo: base)
            }
            // A file whose address was typed into its field: the user's own choice of that server.
            kernel.userTyped(location: leftField.stringValue, relativeTo: base, proposal: session.displayPath(.left))
            kernel.userTyped(location: rightField.stringValue, relativeTo: base, proposal: session.displayPath(.right))
            session.leftURL = location(leftField)
            session.rightURL = location(rightField)
            jumpsToFirstDifference = true
            resyncMarks = (nil, nil)
            session.compare()
        }
    }

    @objc
    private func pickLeft() { pickFile(for: leftField) }
    @objc
    private func pickRight() { pickFile(for: rightField) }

    private func pickFile(for field: NSTextField) {
        effects.chooseFile(toolWindow) { [weak self] url in
            guard let self, let url else {
                return
            }
            field.stringValue = url.path
            if !leftField.stringValue.isEmpty, !rightField.stringValue.isEmpty { compare() }
        }
    }

    @objc
    private func chooseFont() {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        effects.showFontPanel(self)
    }

    /// Called by the font panel.
    @objc
    func changeFont(_ sender: NSFontManager?) {
        guard let sender else {
            return
        }
        font = sender.convert(font)
        settings.set(font.fontName, forKey: CompareSettingsKey.fontName)
        settings.set(String(Double(font.pointSize)), forKey: CompareSettingsKey.fontSize)
        refresh()
    }

    /// Redraws everything that follows the session.
    private func refresh() {
        let selection = leftTable.selectedRowIndexes
        let rowHeight = ceil(font.ascender - font.descender + font.leading) + 3
        let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        isMirroring = true
        for table in [leftTable, rightTable] {
            table.rowHeight = rowHeight
            table.tableColumns[0].width = characterWidth * 9
            table.tableColumns[1].width = min(30_000, max(400, CGFloat(session.width + 4) * characterWidth))
            table.reloadData()
            table.selectRowIndexes(selection.filteredIndexSet { $0 < session.rowCount }, byExtendingSelection: false)
        }
        isMirroring = false
        statusLabel.stringValue = session.status
        let isText = !session.isBinary && session.rowCount > 0
        editBox.isEnabled = isText || session.isEditing
        editButtons.forEach { $0.isHidden = !session.isEditing }
        editButtons.last?.isEnabled = session.canUndo
        saveButton.isEnabled = session.hasUnsavedChanges
        differenceButtons.forEach { $0.isEnabled = !session.blocks.isEmpty }
        bytesPopup.isHidden = !session.isBinary
        for box in [caseBox, spacesBox, endingsBox] { box.isEnabled = !session.isBinary }
        if jumpsToFirstDifference, session.phase == .ready, session.rowCount > 0 {
            jumpsToFirstDifference = false
            if let first = session.blocks.first?.lowerBound { go(toRow: first) }
        }
    }

    // MARK: Moving around

    private var currentRow: Int {
        leftTable.selectedRow >= 0 ? leftTable.selectedRow : max(0, leftTable.rows(in: leftTable.visibleRect).location)
    }

    /// The pane the keyboard is in.
    private var focusedSide: CompareSide {
        window?.firstResponder === rightTable ? .right : .left
    }

    /// Selects a row in both panes and shows it near the top.
    ///
    /// (Rows come from the session's current rows: a search that the rows have changed under is
    /// dropped by the session.).
    private func go(toRow row: Int) {
        leftTable.selectRowIndexes([row], byExtendingSelection: false)
        let top = leftTable.rect(ofRow: max(0, row - 3)).minY
        for table in [leftTable, rightTable] {
            table.scroll(NSPoint(x: table.visibleRect.minX, y: top))
        }
    }

    @objc
    private func nextDifference() {
        if let row = session.difference(from: currentRow, forward: true) { go(toRow: row) } else { effects.beep() }
    }

    @objc
    private func previousDifference() {
        if let row = session.difference(from: currentRow, forward: false) { go(toRow: row) } else { effects.beep() }
    }

    @objc
    private func searchNext() { search(forward: true) }

    private func search(forward: Bool) {
        let needle = searchField.stringValue
        guard !needle.isEmpty else {
            window?.makeFirstResponder(searchField)
            return
        }
        statusLabel.stringValue = "Searching for \"\(needle)\"…"
        session.find(needle, from: currentRow, forward: forward) { [weak self] row in
            self?.searchEnded(needle, at: row)
        }
    }

    /// Shows the row the search found, or says it found none.
    private func searchEnded(_ needle: String, at row: Int?) {
        if let row {
            statusLabel.stringValue = session.status
            go(toRow: row)
        } else {
            statusLabel.stringValue = "\"\(needle)\" was not found."
            effects.beep()
        }
    }

    @objc
    private func paneScrolled(_ notification: Notification) {
        guard !isMirroring, let moved = notification.object as? NSClipView else {
            return
        }
        isMirroring = true
        for table in [leftTable, rightTable] {
            guard let clip = table.enclosingScrollView?.contentView, clip !== moved,
                clip.bounds.origin != moved.bounds.origin
            else { continue }
            clip.scroll(to: moved.bounds.origin)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        isMirroring = false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isMirroring, let changed = notification.object as? NSTableView else {
            return
        }
        isMirroring = true
        let other = changed === leftTable ? rightTable : leftTable
        other.selectRowIndexes(changed.selectedRowIndexes, byExtendingSelection: false)
        isMirroring = false
    }

    // MARK: Editing

    /// The rows "Copy" works on: the selected rows when several are, else the difference the
    /// cursor is in, else the cursor's row.
    private var rowsToCopy: Range<Int>? {
        let selection = leftTable.selectedRowIndexes
        guard let first = selection.first, let last = selection.last else {
            return nil
        }
        if selection.count > 1 {
            return first..<(last + 1)
        }
        return session.block(containing: first) ?? first..<(first + 1)
    }

    @objc
    private func copyToRight() {
        if let rows = rowsToCopy { session.copy(rows: rows, to: .right) }
    }

    @objc
    private func copyToLeft() {
        if let rows = rowsToCopy { session.copy(rows: rows, to: .left) }
    }

    @objc
    private func undoEdit() {
        session.undo()
    }

    @objc
    private func save() {
        session.save()
    }

    @objc
    private func cellEdited(_ sender: NSTextField) {
        for (table, side) in [(leftTable, CompareSide.left), (rightTable, .right)] {
            let row = table.row(for: sender)
            if row >= 0 { session.setText(sender.stringValue, side, row: row) }
        }
    }

    @objc
    private func markResync() {
        let row = currentRow
        if focusedSide == .left { resyncMarks.left = row } else { resyncMarks.right = row }
        if let left = resyncMarks.left, let right = resyncMarks.right {
            resyncMarks = (nil, nil)
            session.resync(leftRow: left, rightRow: right)
        } else {
            statusLabel.stringValue =
                "Line marked on the \(focusedSide == .left ? "left" : "right"). "
                + "Now select the line that belongs to it in the other pane and choose Resync again."
        }
    }

    @objc
    private func clearResync() {
        resyncMarks = (nil, nil)
        session.clearResync()
    }

    @objc
    private func swapSides() {
        session.swap()
        pullControls()
    }

    @objc
    private func copySelection() {
        let side = focusedSide
        let lines = leftTable.selectedRowIndexes.compactMap { session.text(side, row: $0) }
        effects.pasteboard.clearContents()
        effects.pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// The keys of the panes (spec 09 › Compare by content › Keys).
    private func handleKey(_ event: NSEvent) -> Bool {
        func key(_ character: String, _ modifiers: KeyModifiers) -> Bool {
            Shortcut(.character(character), modifiers).matches(event)
        }
        if Shortcut(.downArrow, .option).matches(event) {
            nextDifference()
        } else if Shortcut(.upArrow, .option).matches(event) {
            previousDifference()
        } else if Shortcut.f(6).matches(event) {
            session.setEditing(!session.isEditing)
            pullControls()
        } else if Shortcut.f(3).matches(event) {
            search(forward: true)
        } else if Shortcut.f(3, .shift).matches(event) {
            search(forward: false)
        } else if key("f", .control) || key("f", .command) || Shortcut.f(7).matches(event) {
            window?.makeFirstResponder(searchField)
        } else if key("s", .control) || key("s", .command) {
            save()
        } else if key("z", .control) || key("z", .command) || Shortcut(.backspace, .option).matches(event) {
            undoEdit()
        } else if key("u", .control) {
            swapSides()
        } else if key("c", .command) || key("c", .control) {
            copySelection()
        } else if session.isEditing, Shortcut(.rightArrow, .option).matches(event) {
            copyToRight()
        } else if session.isEditing, Shortcut(.leftArrow, .option).matches(event) {
            copyToLeft()
        } else {
            return false
        }
        return true
    }

    // MARK: Tables

    func numberOfRows(in _: NSTableView) -> Int { session.rowCount }

    private func side(of tableView: NSTableView) -> CompareSide { tableView === leftTable ? .left : .right }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffRowView
            ?? {
                let view = DiffRowView()
                view.identifier = identifier
                return view
            }()
        let hasLine = session.text(side(of: tableView), row: row) != nil
        switch session.kind(ofRow: row) {
        case .equal:
            view.fill = nil

        case .changed:
            view.fill =
                hasLine ? NSColor.systemYellow.withAlphaComponent(0.16) : NSColor.systemGray.withAlphaComponent(0.14)

        case .added, .removed:
            view.fill =
                hasLine ? NSColor.systemRed.withAlphaComponent(0.14) : NSColor.systemGray.withAlphaComponent(0.14)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let side = side(of: tableView)
        let isNumber = tableColumn?.identifier.rawValue == "number"
        let identifier = NSUserInterfaceItemIdentifier(isNumber ? "number" : "text")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byClipping
                label.cell?.usesSingleLineMode = true
                label.target = self
                label.action = #selector(cellEdited(_:))
                return label
            }()
        let differs = session.kind(ofRow: row) != .equal
        if isNumber {
            cell.alignment = .right
            cell.font = font
            cell.textColor = differs ? .systemRed : .secondaryLabelColor
            cell.stringValue = session.label(side, row: row)
            return cell
        }
        let text = session.text(side, row: row)
        cell.isEditable = session.isEditing && text != nil && session.phase == .ready
        // A cell shows the start of a line, never the whole of a line of megabytes: laying that out takes seconds.
        // An edited cell that was cut is not editable, so that the cut part cannot be lost.
        let shown = text.map { $0.utf8.count > 4 * TextDiff.inlineLimit ? String($0.prefix(TextDiff.inlineLimit)) : $0 }
        if let text, let shown, shown.utf8.count != text.utf8.count { cell.isEditable = false }
        let attributed = NSMutableAttributedString(
            string: shown ?? "",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        for range in session.highlights(side, row: row) where range.lowerBound < attributed.length {
            attributed.addAttributes(
                [.backgroundColor: NSColor.systemRed.withAlphaComponent(0.30), .foregroundColor: NSColor.labelColor],
                range: NSRange(
                    location: range.lowerBound,
                    length: min(range.upperBound, attributed.length) - range.lowerBound
                )
            )
        }
        cell.attributedStringValue = attributed
        return cell
    }

    // MARK: Window

    func windowShouldClose(_: NSWindow) -> Bool {
        guard session.hasUnsavedChanges else {
            return true
        }
        // Closing this way does not ask again; whatever was not saved is given up.
        whenChangesAreSettled { [weak self] in self?.close() }
        return false
    }

    func windowWillClose(_: Notification) {
        NotificationCenter.default.removeObserver(self)
        if NSFontManager.shared.target === self { NSFontManager.shared.target = nil }
        session.cancel()
        onClose(self)
    }
}
