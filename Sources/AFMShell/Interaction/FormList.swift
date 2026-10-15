import AppKit

/// A list field of a form.
///
/// A long list has a field above it: what is typed there narrows the list down to the rows that
/// contain it, while ↑ and ↓ still move through the rows. A short list finds a row by typing its
/// beginning. Main thread only.
@MainActor
internal final class FormList: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Lists longer than this get the filter field.
    internal static let filterThreshold = 12

    /// Every row of the list.
    internal let rows: [String]
    /// The table that shows the rows.
    internal let table = NSTableView()
    /// The filter field of a long list; nil for a short one.
    internal let searchField: NSSearchField?
    /// The view to put into the form: the table, with the filter field above it when there is one.
    internal let view: NSView
    /// Called for a double click on a row.
    internal var onAccept: (() -> Void)?
    /// The rows the list shows now, as positions in `rows`.
    internal private(set) var shown: [Int]

    /// The view that takes the keyboard: the filter field when there is one.
    internal var keyboardView: NSView { searchField ?? table }

    /// The chosen row as a position in `rows`; -1 when none is chosen.
    internal var selectedRow: Int {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : -1
    }

    /// A list of `rows`, `width` wide, with the row `selected` chosen.
    internal init(rows: [String], selected: Int, width: CGFloat) {
        self.rows = rows
        shown = Array(rows.indices)
        let scroll = Self.makeScrollView(around: table, rows: rows.count, width: width)
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

    /// The table with one column and no header, in a scroll view as high as its rows need
    /// within limits.
    private static func makeScrollView(around table: NSTableView, rows: Int, width: CGFloat) -> NSScrollView {
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
        scroll.heightAnchor.constraint(equalToConstant: min(320, max(90, CGFloat(rows) * 20 + 4))).isActive = true
        return scroll
    }

    /// Brings the chosen row into view, once the list has its size.
    internal func showSelection() {
        if table.selectedRow >= 0 {
            table.scrollRowToVisible(table.selectedRow)
        }
    }

    /// Shows only the rows that contain `text`, whatever its case and accents.
    ///
    /// The chosen row stays chosen while it is shown; otherwise the first row is.
    internal func filter(_ text: String) {
        let chosen = selectedRow
        let wanted = text.trimmingCharacters(in: .whitespaces)
        shown = rows.indices.filter { index in
            wanted.isEmpty || rows[index].range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        table.reloadData()
        table.deselectAll(nil)
        select(shown.contains(chosen) ? chosen : shown.first ?? -1)
    }

    /// Moves the chosen row by `delta` rows, staying inside the list.
    internal func moveSelection(by delta: Int) {
        guard !shown.isEmpty else {
            return
        }
        let position = min(shown.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes([position], byExtendingSelection: false)
        table.scrollRowToVisible(position)
    }

    /// The filter field changed: the list follows.
    internal func controlTextDidChange(_: Notification) {
        if let searchField {
            filter(searchField.stringValue)
        }
    }

    /// From the filter field the arrow and page keys move through the list.
    internal func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        let page = max(1, table.rows(in: table.visibleRect).length - 1)
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)

        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)

        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            moveSelection(by: -page)

        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            moveSelection(by: page)

        default:
            return false
        }
        return true
    }

    /// The number of rows shown.
    internal func numberOfRows(in _: NSTableView) -> Int { shown.count }

    /// The cell of a row: its text, cut in the middle when it is too long, in full as its tooltip.
    internal func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let label =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        // The table asks only for the rows it has (`numberOfRows`).
        let text = rows[shown[row]]
        label.stringValue = text
        label.toolTip = text
        return label
    }

    /// What typing the beginning of a row finds it by: its text.
    internal func tableView(_: NSTableView, typeSelectStringFor _: NSTableColumn?, row: Int) -> String? {
        rows[shown[row]]
    }

    /// Chooses the row at position `row` of `rows`, when it is shown.
    private func select(_ row: Int) {
        guard let position = shown.firstIndex(of: row) else {
            return
        }
        table.selectRowIndexes([position], byExtendingSelection: false)
        table.scrollRowToVisible(position)
    }

    /// A double click on a row accepts the form.
    @objc
    private func rowDoubleClicked() {
        if table.clickedRow >= 0 {
            onAccept?()
        }
    }

    deinit {
        // Nothing to release.
    }
}
