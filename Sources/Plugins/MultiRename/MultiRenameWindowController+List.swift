import AFMContracts
import AFMKernel
import AppKit

/// The list of the items: its cells, sorting by a column and reordering by drag and drop.
extension MultiRenameWindowController {
    /// One row per item.
    internal func numberOfRows(in _: NSTableView) -> Int { session.rowCount }

    /// The cell of a row in a column: old name, extension, new name (red where it cannot be used),
    /// size, date, location.
    internal func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier, row >= 0, row < session.rowCount else {
            return nil
        }
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
        let parts = entry.item.isFolder ? (base: entry.name, ext: "") : FileItem.split(entry.name)
        cell.textColor = .labelColor
        cell.alignment = .left
        cell.toolTip = nil
        switch column.rawValue {
        case "old":
            cell.stringValue = parts.base

        case "ext":
            cell.stringValue = parts.ext

        case "new":
            cell.stringValue = shown.newName ?? RenameEngine.errorText
            mark(cell, by: shown.status)

        case "size":
            cell.stringValue = entry.item.isFolder ? "<DIR>" : Format.bytes(entry.item.size)
            cell.alignment = .right

        case "date":
            cell.stringValue = Self.dateFormatter.string(from: entry.item.modified)

        default:
            cell.stringValue = kernel.fileSystems.displayPath(entry.directory) + "/"
        }
        return cell
    }

    /// A click on a header sorts by that column; a second click turns the order.
    internal func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let keys: [String: MultiRenameSession.SortKey] = ["old": .name, "ext": .ext, "size": .size, "date": .date]
        guard let key = keys[tableColumn.identifier.rawValue] else {
            return
        }
        sortAscending = sortColumn == tableColumn.identifier.rawValue ? !sortAscending : true
        sortColumn = tableColumn.identifier.rawValue
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }
        tableView.setIndicatorImage(
            NSImage(named: sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
            in: tableColumn
        )
        session.sort(by: key, ascending: sortAscending)
    }

    /// A row is dragged as its number.
    internal func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> any NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    /// Only the list's own rows can be dropped, and only between rows.
    internal func tableView(
        _: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow _: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        (info.draggingSource as? NSTableView) === table && dropOperation == .above ? .move : []
    }

    /// The dragged rows move in front of `row`.
    internal func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        // The rows come from this table's own drag, whose pasteboard always holds its items.
        // swiftlint:disable:next force_unwrapping
        let rows = info.draggingPasteboard.pasteboardItems!
            .compactMap { item in
                item.string(forType: Self.rowType).flatMap(Int.init)
            }
        guard !rows.isEmpty else {
            return false
        }
        // A reordered list is no longer sorted by any column.
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }
        sortColumn = nil
        let moved = session.move(IndexSet(rows), to: row)
        table.selectRowIndexes(moved, byExtendingSelection: false)
        return true
    }

    /// The colour and the tip of a new name by how it stands.
    private func mark(_ cell: NSTextField, by status: RenameStatus) {
        switch status {
        case .unchanged:
            cell.textColor = .secondaryLabelColor

        case .ready:
            break

        case .error:
            cell.textColor = .systemRed

        case .invalid(let reason):
            (cell.textColor, cell.toolTip) = (.systemRed, reason)

        case .duplicate:
            (cell.textColor, cell.toolTip) = (.systemRed, "Another file in the list gets the same name.")

        case .exists:
            (cell.textColor, cell.toolTip) = (.systemRed, "A file with this name already exists.")
        }
    }
}
