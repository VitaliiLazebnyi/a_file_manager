import AFMKernel
import AppKit

/// Shows a plugin's form (`UserInteraction.form`) as an alert with one row per field. A form
/// with more rows than fit is scrolled; a long list gets a field that narrows it down.
/// Return takes the first button, Esc cancels, a double click on a list row accepts.
@MainActor
final class FormDialog: NSObject, NSTextViewDelegate {
    private let fields: [FormField]
    private var controls: [(field: FormField, read: () -> FormValues.Value)] = []
    private(set) var lists: [FormList] = []
    private weak var alert: NSAlert?
    private var focusObservation: NSKeyValueObservation?
    /// The view that takes the keyboard when the dialog opens.
    private(set) var firstInput: NSView?
    /// The scroll view around the rows, when they do not fit.
    private(set) var scrollView: NSScrollView?

    static let fieldWidth: CGFloat = 380
    static let labelWidth: CGFloat = 200

    /// The height the rows may take before they are scrolled: what the screen has left beside
    /// the alert's own title, text and buttons.
    static var maximumHeight: CGFloat {
        min(560, max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 340))
    }

    init(fields: [FormField]) {
        self.fields = fields
    }

    func run(title: String, detail: String, buttons: [String]) -> FormValues? {
        let alert = makeAlert(title: title, detail: detail, buttons: buttons)
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        focusObservation = nil
        return buttons.indices.contains(response) ? values(button: response) : nil
    }

    /// What the fields hold now, as the answer given with a button.
    func values(button: Int) -> FormValues {
        var answer = FormValues(button: button)
        for control in controls { answer.values[control.field.key] = control.read() }
        return answer
    }

    /// Builds the dialog without showing it.
    func makeAlert(title: String, detail: String, buttons: [String], maximumHeight: CGFloat = FormDialog.maximumHeight)
        -> NSAlert
    {
        let alert = NSAlert()
        // Titles and texts may name files and servers; see `AlertInteraction`.
        alert.messageText = DisplayText.clean(title, keepingLines: true)
        alert.informativeText = DisplayText.clean(detail, keepingLines: true)
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        self.alert = alert

        let rows: [[NSView]] = fields.map { field in
            let label = NSTextField(labelWithString: field.label)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            guard let control = makeControl(for: field) else {
                // A note takes the whole width.
                label.preferredMaxLayoutWidth = Self.fieldWidth + 120
                return [label]
            }
            if case .checkbox = field.kind { return [NSGridCell.emptyContentView, control] }
            control.setAccessibilityLabel(field.label)
            label.alignment = .right
            label.preferredMaxLayoutWidth = Self.labelWidth
            return field.label.isEmpty ? [control] : [label, control]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for (index, row) in rows.enumerated() where row.count == 1 {
            grid.mergeCells(
                inHorizontalRange: NSRange(location: 0, length: grid.numberOfColumns),
                verticalRange: NSRange(location: index, length: 1)
            )
        }
        if grid.numberOfColumns > 1 { grid.column(at: 0).xPlacement = .trailing }
        grid.rowAlignment = .firstBaseline
        let size = grid.fittingSize
        grid.frame = NSRect(origin: .zero, size: size)
        if size.height > maximumHeight {
            alert.accessoryView = makeScrollView(around: grid, height: maximumHeight)
        } else {
            alert.accessoryView = grid
        }
        alert.window.initialFirstResponder = firstInput
        alert.window.recalculateKeyViewLoop()
        alert.layout()
        lists.forEach { $0.showSelection() }
        // A field reached with Tab is brought into view.
        if scrollView != nil {
            focusObservation = alert.window.observe(\.firstResponder) { window, _ in
                // The first responder changes on the main thread, where this is called.
                MainActor.assumeIsolated {
                    // The field editor stands in for the text field it edits.
                    let responder = window.firstResponder
                    let view = ((responder as? NSTextView)?.delegate as? NSView) ?? responder as? NSView
                    if let view { view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -8)) }
                }
            }
        }
        return alert
    }

    private func makeScrollView(around grid: NSGridView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: grid.frame.width + 20, height: height))
        // Flipped, so the form starts at its first row.
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scrollView = scroll
        return scroll
    }

    private func takesKeyboard(_ view: NSView) {
        if firstInput == nil { firstInput = view }
    }

    private func makeControl(for field: FormField) -> NSView? {
        let width = Self.fieldWidth
        switch field.kind {
        case .note:
            return nil

        case .text(let value):
            let input = NSTextField(string: value)
            configure(input, width: width)
            controls.append((field, { .text(input.stringValue) }))
            return input

        case .secureText:
            let input = NSSecureTextField(string: "")
            configure(input, width: width)
            controls.append((field, { .text(input.stringValue) }))
            return input

        case .multilineText(let value):
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
            textView.string = value
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.delegate = self
            let scroll = NSScrollView()
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
            takesKeyboard(textView)
            controls.append((field, { .text(textView.string) }))
            return scroll

        case .checkbox(let isOn):
            let box = NSButton(checkboxWithTitle: field.label, target: nil, action: nil)
            box.state = isOn ? .on : .off
            controls.append((field, { .flag(box.state == .on) }))
            return box

        case .choice(let options, let selected):
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            // Added one by one: `addItems` drops options with the same caption.
            for option in options {
                popUp.menu?.addItem(NSMenuItem(title: option, action: nil, keyEquivalent: ""))
            }
            if options.indices.contains(selected) { popUp.selectItem(at: selected) }
            popUp.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
            controls.append((field, { .index(popUp.indexOfSelectedItem) }))
            return popUp

        case .list(let rows, let selected):
            let list = FormList(rows: rows, selected: selected, width: width)
            list.onAccept = { [weak self] in self?.alert?.buttons.first?.performClick(nil) }
            lists.append(list)
            takesKeyboard(list.keyboardView)
            controls.append((field, { .index(list.selectedRow) }))
            return list.view
        }
    }

    private func configure(_ input: NSTextField, width: CGFloat) {
        // A long path scrolls inside its one line instead of being cut off.
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.widthAnchor.constraint(equalToConstant: width).isActive = true
        takesKeyboard(input)
    }

    /// In a box for several lines Return starts a new line; Tab goes on to the next field
    /// instead of writing a tab, so the dialog can be left with the keyboard.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): textView.window?.selectNextKeyView(nil)
        case #selector(NSResponder.insertBacktab(_:)): textView.window?.selectPreviousKeyView(nil)
        default: return false
        }
        return true
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A list field of a form. A long list has a field above it: what is typed there narrows the
/// list down to the rows that contain it, while ↑ and ↓ still move through the rows. A short
/// list finds a row by typing its beginning.
@MainActor
final class FormList: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Lists longer than this get the filter field.
    static let filterThreshold = 12

    let rows: [String]
    /// The rows the list shows now, as positions in `rows`.
    private(set) var shown: [Int]
    let table = NSTableView()
    let searchField: NSSearchField?
    let view: NSView
    /// Called for a double click on a row.
    var onAccept: (() -> Void)?

    init(rows: [String], selected: Int, width: CGFloat) {
        self.rows = rows
        shown = Array(rows.indices)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.width = width - 20
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 18
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(320, max(90, CGFloat(rows.count) * 20 + 4))).isActive = true
        if rows.count > Self.filterThreshold {
            let search = NSSearchField()
            search.placeholderString = "Filter"
            search.sendsSearchStringImmediately = true
            search.widthAnchor.constraint(equalToConstant: width).isActive = true
            searchField = search
            let stack = NSStackView(views: [search, scroll])
            stack.orientation = .vertical
            stack.spacing = 6
            view = stack
        } else {
            searchField = nil
            view = scroll
        }
        super.init()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        searchField?.delegate = self
        table.reloadData()
        select(selected)
    }

    /// The view that takes the keyboard: the filter field when there is one.
    var keyboardView: NSView { searchField ?? table }

    /// The chosen row as a position in `rows`; -1 when none is chosen.
    var selectedRow: Int {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : -1
    }

    private func select(_ row: Int) {
        guard let position = shown.firstIndex(of: row) else { return }
        table.selectRowIndexes([position], byExtendingSelection: false)
        table.scrollRowToVisible(position)
    }

    /// Brings the chosen row into view, once the list has its size.
    func showSelection() {
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }

    /// Shows only the rows that contain `text`, whatever its case and accents. The chosen row
    /// stays chosen while it is shown; otherwise the first row is.
    func filter(_ text: String) {
        let chosen = selectedRow
        let text = text.trimmingCharacters(in: .whitespaces)
        shown = rows.indices.filter {
            text.isEmpty || rows[$0].range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        table.reloadData()
        table.deselectAll(nil)
        select(shown.contains(chosen) ? chosen : shown.first ?? -1)
    }

    /// Moves the chosen row by `delta` rows, staying inside the list.
    func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let position = min(shown.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes([position], byExtendingSelection: false)
        table.scrollRowToVisible(position)
    }

    @objc private func rowDoubleClicked() {
        if table.clickedRow >= 0 { onAccept?() }
    }

    func controlTextDidChange(_: Notification) {
        if let searchField { filter(searchField.stringValue) }
    }

    /// From the filter field the arrow and page keys move through the list.
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        let page = max(1, table.rows(in: table.visibleRect).length - 1)
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): moveSelection(by: -page)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): moveSelection(by: page)
        default: return false
        }
        return true
    }

    func numberOfRows(in _: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let label =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        let text = shown.indices.contains(row) ? rows[shown[row]] : ""
        label.stringValue = text
        label.toolTip = text
        return label
    }

    func tableView(_: NSTableView, typeSelectStringFor _: NSTableColumn?, row: Int) -> String? {
        shown.indices.contains(row) ? rows[shown[row]] : nil
    }
}
