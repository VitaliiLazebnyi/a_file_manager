import AFMContracts
import AFMKernel
import AppKit

/// Table: the cells of the result list, their texts and colours, and sorting by a column.
extension SyncWindowController {
    /// The text of a row in a column: a name, a size or a date of one side, or the middle column's symbol.
    internal static func text(of row: SyncRow, column: String) -> String {
        func size(_ item: FileItem?) -> String {
            item.map { found in row.isDirectory ? "<DIR>" : Format.bytes(found.size) } ?? ""
        }
        func date(_ item: FileItem?) -> String {
            item.map { found in dateFormatter.string(from: found.modified) } ?? ""
        }
        func name(_ item: FileItem?) -> String {
            item.map { found in row.isDirectory ? "[\(found.name)]" : found.name } ?? ""
        }
        let texts: [String: (FileItem?) -> String] = [
            "leftName": name, "leftSize": size, "leftDate": date, "rightName": name, "rightSize": size,
            "rightDate": date
        ]
        guard let text = texts[column] else {
            return middle(of: row)
        }
        return text(column.hasPrefix("left") ? row.left : row.right)
    }

    /// The middle column: the symbol of the row's action, or, without one, what the comparison found.
    private static func middle(of row: SyncRow) -> String {
        if row.action != .nothing {
            return row.action.symbol
        }
        switch row.state {
        case .equal:
            return "="

        case .pending:
            return "?"

        case .excluded:
            return "⊘"

        default:
            return "≠"
        }
    }

    /// The colour shows what the comparison proposed (spec 09 › Result list).
    internal static func color(of row: SyncRow) -> NSColor {
        switch row.defaultAction {
        case .copyToRight:
            return .systemGreen

        case .copyToLeft, .deleteRight:
            return .systemBlue

        default:
            switch row.state {
            case .equal:
                return .labelColor

            case .excluded, .pending:
                return .secondaryLabelColor

            default:
                return .systemRed
            }
        }
    }

    /// As many lines as the list has: captions and rows.
    internal func numberOfRows(in _: NSTableView) -> Int { session.entries.count }

    /// The captions of the subdirectories are group rows.
    internal func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = session.entries[row] {
            return true
        }
        return false
    }

    /// Only rows are selected, never captions.
    internal func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = session.entries[row] {
            return false
        }
        return true
    }

    /// The cell of a line: a caption, or a row's text in the column, in the row's colour.
    internal func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "header"
        let identifier = NSUserInterfaceItemIdentifier("cell." + id)
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
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
            cell.textColor = Self.color(of: item)
            cell.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.alignment = id.hasSuffix("Size") ? .right : (id == "action" ? .center : .left)
            cell.stringValue = Self.text(of: item, column: id)
        }
        return cell
    }

    /// A click on a column header sorts by name, size or date of that side; again reverses.
    internal func tableView(_: NSTableView, didClick tableColumn: NSTableColumn) {
        let id = tableColumn.identifier.rawValue
        guard id != "action" else {
            return
        }
        let side: SyncSide = id.hasPrefix("left") ? .left : .right
        let key: SyncSortKey = id.hasSuffix("Size") ? .size : (id.hasSuffix("Date") ? .date : .name)
        let same = session.sort.key == key && session.sort.side == side
        session.sort = SyncSort(key: key, side: side, ascending: same ? !session.sort.ascending : true)
    }

    /// The selection moved: the subdirectory indicator follows it.
    internal func tableViewSelectionDidChange(_: Notification) {
        updateIndicator()
    }
}
