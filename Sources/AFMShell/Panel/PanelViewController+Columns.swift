import AFMContracts
import AFMKernel
import AppKit

/// The columns of the Full view and the header of every view: plugin columns, widths, sorting
/// by a click on the header, and the header's menu (spec 03 › Custom columns, 03 › Header clicks).
extension PanelViewController {
    /// The prefix of the identifiers of plugin columns in the table, which keeps them apart
    /// from the standard columns whatever a plugin calls its column.
    internal static let extraColumnPrefix = "+"

    /// What the panel remembers of its looks between sessions.
    internal var viewState: PanelViewState {
        get {
            rememberColumnWidths()
            return PanelViewState(mode: viewMode.rawValue, extraColumns: extraColumns, columnWidths: columnWidths)
        }
        set {
            columnWidths = newValue.columnWidths
            extraColumns = newValue.extraColumns
            viewMode = newValue.viewMode
        }
    }

    /// Shows the plugin columns of `extraColumns` after the standard ones. An id no plugin
    /// offers (its plugin is not there) is kept in the list but shows nothing.
    internal func rebuildExtraColumns() {
        guard isViewLoaded else {
            return
        }
        rememberColumnWidths()
        for column in tableView.tableColumns where column.identifier.rawValue.hasPrefix(Self.extraColumnPrefix) {
            tableView.removeTableColumn(column)
        }
        var shown: Set<String> = []
        for id in extraColumns where shown.insert(id).inserted {
            guard let column = kernel.columns[id] else {
                continue
            }
            let identifier = Self.extraColumnPrefix + id
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            tableColumn.title = column.title
            tableColumn.width = CGFloat(columnWidths[identifier] ?? Double(column.width))
            tableColumn.minWidth = 30
            tableColumn.resizingMask = .userResizingMask
            if column.alignsRight {
                tableColumn.headerCell.alignment = .right
            }
            tableView.addTableColumn(tableColumn)
        }
        if !showsGrid {
            reloadList(full: true)
        }
    }

    /// Notes the widths the columns have now, so they can be remembered.
    internal func rememberColumnWidths() {
        guard isViewLoaded else {
            return
        }
        for column in tableView.tableColumns {
            columnWidths[column.identifier.rawValue] = Double(column.width)
        }
    }

    /// Values of plugin columns were computed: the rows on screen that show them are drawn again.
    internal func columnValuesArrived(for names: Set<String>) {
        guard !showsGrid else {
            return
        }
        let columns = IndexSet(
            tableView.tableColumns.indices.filter {
                tableView.tableColumns[$0].identifier.rawValue.hasPrefix(Self.extraColumnPrefix)
            }
        )
        let visible = tableView.rows(in: tableView.visibleRect)
        let rows = IndexSet(
            (visible.location..<(visible.location + visible.length)).filter { row in
                model.item(atRow: row).map { names.contains($0.name) } ?? false
            }
        )
        if !rows.isEmpty, !columns.isEmpty {
            tableView.reloadData(forRowIndexes: rows, columnIndexes: columns)
        }
    }

    /// A click on a column header: the column's sort command, or Reversed Order when the list
    /// is already sorted by that column (spec 03 › Header clicks).
    internal func headerClicked(_ column: FileListColumn) {
        guard let key = column.sortKey, let command = column.sortCommand else {
            return
        }
        performFocused(key == model.wantedSort.key ? .reversedOrder : command, .nothing)
    }

    /// The menu of the column header: the views, the plugin columns to show or hide, and the
    /// dialog for them (spec 05 › Column header). It acts on this panel, which becomes the source.
    internal func fillHeaderMenu() {
        focus()
        headerMenu.removeAllItems()
        let views = MenuBuilder.menu(
            "",
            [.viewBrief, .viewFull, .viewThumbnails],
            commands: commands,
            keys: kernel.keyBindings
        )
        for item in views.items {
            views.removeItem(item)
            item.state = commands.isChecked(MenuBuilder.command(of: item) ?? "") ? .on : .off
            headerMenu.addItem(item)
        }
        if !kernel.columns.all.isEmpty, !headerMenu.items.isEmpty {
            headerMenu.addItem(.separator())
        }
        for column in kernel.columns.all {
            let item = headerMenu.addItem(
                withTitle: column.title,
                action: #selector(extraColumnChosen(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.id
            item.state = extraColumns.contains(column.id) ? .on : .off
        }
        if let configure = commands[PanelShellCommands.customColumns] {
            headerMenu.addItem(.separator())
            headerMenu.addItem(MenuBuilder.item(configure, keys: kernel.keyBindings))
        }
    }

    /// The header menu, filled (for the header of the grid, which has no menu of its own).
    internal func filledHeaderMenu() -> NSMenu {
        fillHeaderMenu()
        return headerMenu
    }

    /// A plugin column was chosen in the header menu: it is shown, or hidden.
    @objc
    internal func extraColumnChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        toggleExtraColumn(id)
    }

    /// Shows a plugin column that is hidden, at the end, and hides one that is shown.
    internal func toggleExtraColumn(_ id: String) {
        if extraColumns.contains(id) {
            extraColumns.removeAll { $0 == id }
        } else {
            extraColumns.append(id)
        }
    }
}
