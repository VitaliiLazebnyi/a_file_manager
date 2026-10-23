import AFMContracts
import AFMKernel
import AppKit

/// The result list as a table, and its lines as text.
extension FindFilesWindowController {
    /// The rows as text, one line each: the summary, an empty line for a separator, each result.
    nonisolated internal static func copyText(
        of rows: [Row],
        showsDuplicates: Bool,
        fileSystems: FileSystemRegistry
    ) -> String {
        var copied: [String] = []
        copied.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case .summary(let text):
                copied.append(text)

            case .separator:
                copied.append("")

            case .item(let item):
                copied.append(Self.text(of: item, showsDuplicates: showsDuplicates, fileSystems: fileSystems))
            }
        }
        return copied.joined(separator: "\n")
    }

    /// The line of a result: its path, or for a duplicate `name  -  folder/`.
    nonisolated internal static func text(
        of item: FileItem,
        showsDuplicates: Bool,
        fileSystems: FileSystemRegistry
    ) -> String {
        guard showsDuplicates else {
            return fileSystems.displayPath(item.url)
        }
        // Duplicates read `name  -  folder/` (spec 09 › Duplicate finder, Output).
        let folder = fileSystems.displayPath(item.url.deletingLastPathComponent())
        return "\(item.name)  -  \(folder.hasSuffix("/") ? folder : folder + "/")"
    }

    /// One line per row.
    internal func numberOfRows(in _: NSTableView) -> Int { rows.count }

    /// The text of a row; the summary and the separators in the secondary colour.
    internal func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("path")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingMiddle
                return label
            }()
        cell.stringValue = text(of: rows[row])
        if case .item = rows[row] {
            cell.textColor = .labelColor
        } else {
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }

    /// A separator cannot be selected.
    internal func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .separator = rows[row] {
            return false
        }
        return true
    }

    /// After a search the status line shows the size, date and permissions of the result
    /// under the cursor, which the list itself does not.
    internal func tableViewSelectionDidChange(_: Notification) {
        updateButtons()
        guard !isSearching else {
            return
        }
        if let item = selectedItem {
            let size = item.isDirectory ? "<DIR>" : Format.bytes(item.size)
            statusLabel.stringValue =
                "\(item.name)   \(size)  \(Format.date(item.modified))  \(Format.permissions(item.permissions))"
        } else if case .summary(let text)? = rows.first {
            statusLabel.stringValue = text
        }
    }
}
