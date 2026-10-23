import AppKit

/// A list of text rows in columns, as the editors of the configuration windows use it.
///
/// Main thread only.
internal final class RowsTable: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
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
    /// Called when the selection changed.
    internal var onSelect: (() -> Void)?
    /// A double click or Return on a row.
    internal var onActivate: (() -> Void)? {
        didSet { table.onReturn = { [weak self] in self?.onActivate?() } }
    }

    /// The table inside, for the first responder and for tests.
    internal var tableView: NSTableView { table }

    /// The selected row; nil when none is.
    internal var selectedRow: Int? {
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

    /// An empty list with these columns; with every title empty it has no header.
    internal init(columns: [(title: String, width: CGFloat)]) {
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

    /// Not used: the list is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) { fatalError("not used") }

    /// Shows other rows and keeps the selection on the same position where there still is one.
    internal func show(_ rows: [[String]], symbols: [String?], selecting row: Int?) {
        let selected = row ?? selectedRow
        self.rows = rows
        self.symbols = symbols
        table.reloadData()
        selectedRow = selected.map { min($0, rows.count - 1) }
    }

    /// The number of rows shown.
    internal func numberOfRows(in _: NSTableView) -> Int { rows.count }

    /// A label with the row's text of the column, and the row's symbol in front in the first column.
    internal func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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

    /// Passes a change of the selection on to `onSelect`.
    internal func tableViewSelectionDidChange(_: Notification) { onSelect?() }

    @objc
    private func doubleClicked() {
        if table.clickedRow >= 0 { onActivate?() }
    }
}
