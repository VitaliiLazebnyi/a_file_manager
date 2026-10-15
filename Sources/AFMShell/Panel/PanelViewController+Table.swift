import AFMContracts
import AFMKernel
import AppKit

/// The table of the Full view: the panel is its data source and delegate (spec 03 › Rows in
/// Full view).
extension PanelViewController {
    /// The rows of the active tab, `[..]` included.
    internal func numberOfRows(in _: NSTableView) -> Int {
        model.rowCount
    }

    /// Row views are used again like cells: scrolling and reloading would otherwise make one
    /// for every row that comes into sight.
    internal func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let rowView =
            tableView.makeView(withIdentifier: CursorRowView.reuseIdentifier, owner: nil) as? CursorRowView
            ?? CursorRowView()
        rowView.identifier = CursorRowView.reuseIdentifier
        rowView.panel = self
        return rowView
    }

    /// The table's selected row is the cursor: the model follows it.
    internal func tableViewSelectionDidChange(_: Notification) {
        guard !syncing, tableView.selectedRow >= 0 else {
            return
        }
        model.cursor = tableView.selectedRow
        host?.panelCursorDidChange(self)
    }

    /// A click on a column's header sorts by it.
    internal func tableView(_: NSTableView, didClick tableColumn: NSTableColumn) {
        if let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) {
            headerClicked(column)
        }
    }

    /// A column was resized: its width is noted.
    internal func tableViewColumnDidResize(_: Notification) {
        // Widths are written down when the program quits and when the columns change; a drag
        // of a column border would otherwise save on every point of its way.
        rememberColumnWidths()
    }

    /// The cell of a row in a column: a standard column's, or a plugin column's.
    internal func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else {
            return nil
        }
        let cell: NSTableCellView
        if let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) {
            cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView ?? column.makeCell()
        } else if contentColumn(of: tableColumn) != nil {
            cell =
                tableView.makeView(withIdentifier: FileListColumn.extraCellIdentifier, owner: nil) as? NSTableCellView
                ?? FileListColumn.makeExtraCell()
        } else {
            return nil
        }
        fill(cell, of: tableColumn, row: row, look: look(ofRow: row, ownIcons: model.volume?.isLocal ?? false))
        return cell
    }

    /// Brings every row the table has made up to date with the model, where it stands: a cell
    /// is touched only if what it shows differs, so a list that did not change costs a
    /// comparison per cell on screen and nothing is laid out or drawn.
    internal func refreshRows() {
        let ownIcons = model.volume?.isLocal ?? false
        let columns = tableView.tableColumns
        tableView.enumerateAvailableRowViews { rowView, row in
            let look = look(ofRow: row, ownIcons: ownIcons)
            for index in columns.indices {
                guard let cell = rowView.view(atColumn: index) as? NSTableCellView else {
                    continue
                }
                fill(cell, of: columns[index], row: row, look: look)
            }
        }
    }

    /// The plugin column a table column stands for.
    internal func contentColumn(of tableColumn: NSTableColumn) -> ContentColumn? {
        let identifier = tableColumn.identifier.rawValue
        guard identifier.hasPrefix(Self.extraColumnPrefix) else {
            return nil
        }
        return kernel.columns[String(identifier.dropFirst(Self.extraColumnPrefix.count))]
    }

    /// How the row `row` is drawn.
    private func look(ofRow row: Int, ownIcons: Bool) -> RowLook {
        let item = model.item(atRow: row)
        return RowLook(item: item, color: rowNameColor(for: item, selected: model.isSelected(row: row)), ownIcons: ownIcons)
    }

    /// Makes a cell show its row; used for a cell that is new or used again and for one that
    /// stays where it is (`refreshRows`). Nothing is set that is already so.
    private func fill(_ cell: NSTableCellView, of tableColumn: NSTableColumn, row: Int, look: RowLook) {
        if let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) {
            column.fill(cell, with: look)
            // The rename box stands in for the name and the extension of its row.
            if column == .name || column == .ext {
                let isHidden = row == renamingRow
                if cell.textField?.isHidden != isHidden {
                    cell.textField?.isHidden = isHidden
                }
            }
            return
        }
        guard let column = contentColumn(of: tableColumn), let field = cell.textField else {
            return
        }
        let alignment: NSTextAlignment = column.alignsRight ? .right : .left
        if field.alignment != alignment {
            field.alignment = alignment
        }
        if field.textColor != look.color {
            field.textColor = look.color
        }
        // A value that is not known yet is on its way; the cell is filled in when it arrives.
        let text = DisplayText.clean(look.item.flatMap { columnValues.text(of: column, for: $0) } ?? "")
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.accessibilityLabel() != column.title {
            field.setAccessibilityLabel(column.title)
        }
        if field.isAccessibilityElement() == text.isEmpty {
            field.setAccessibilityElement(!text.isEmpty)
        }
    }
}
