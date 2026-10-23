import AppKit

/// Tables: the rows of the two panes, their colours and cells.
extension CompareWindowController {
    /// As many rows as the comparison has, in both panes.
    internal func numberOfRows(in _: NSTableView) -> Int { session.rowCount }

    /// The side a pane shows.
    private func side(of tableView: NSTableView) -> CompareSide { tableView === leftTable ? .left : .right }

    /// A row coloured by what kind of line it is: yellow changed, red added or removed, grey where the side has
    /// no line.
    internal func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
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

    /// The cell of a row: its line number (or offset), or its text with the parts that differ marked.
    internal func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        let shown = text.map { line in
            line.utf8.count > 4 * TextDiff.inlineLimit ? String(line.prefix(TextDiff.inlineLimit)) : line
        }
        if let text, let shown, shown.utf8.count != text.utf8.count {
            cell.isEditable = false
        }
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
}
