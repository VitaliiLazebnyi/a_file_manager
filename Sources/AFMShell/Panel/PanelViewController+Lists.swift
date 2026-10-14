import AFMContracts
import AFMKernel
import AppKit

/// The parts of a panel that differ by view: which list is on screen, how the cursor is shown
/// in it, and the columns of the Full view (spec 03 › View types, 03 › Custom columns).
extension PanelViewController {
    /// The prefix of the identifiers of plugin columns in the table, which keeps them apart
    /// from the standard columns whatever a plugin calls its column.
    static let extraColumnPrefix = "+"

    /// Up to this many rows fewer at once, the table is told the new number and keeps its rows.
    static let rowsRemovedInPlace = 400_000

    /// True while the Brief or the Thumbnails view is on screen.
    var showsGrid: Bool { viewMode != .full }

    /// The list that is on screen; it has the keyboard when the panel is the source.
    var listView: NSView { showsGrid ? gridView : tableView }

    /// Builds the place of the list: the table of the Full view and the grid of the other
    /// views in the same spot, one of them hidden.
    func makeListArea(tableScroll: NSScrollView, gridBox: NSStackView) -> NSView {
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true

        let gridScroll = NSScrollView()
        gridView.panel = self
        gridView.registerForDraggedTypes(PanelDrop.acceptedTypes)
        gridScroll.documentView = gridView
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.backgroundColor = .textBackgroundColor
        sortHeader.onClick = { [weak self] column in self?.headerClicked(column) }
        sortHeader.menuProvider = { [weak self] in
            guard let self else { return nil }
            self.fillHeaderMenu()
            return self.headerMenu
        }
        gridBox.orientation = .vertical
        gridBox.spacing = 0
        gridBox.alignment = .leading
        gridBox.addArrangedSubview(sortHeader)
        gridBox.addArrangedSubview(gridScroll)
        sortHeader.widthAnchor.constraint(equalTo: gridBox.widthAnchor).isActive = true
        gridScroll.widthAnchor.constraint(equalTo: gridBox.widthAnchor).isActive = true

        let area = NSView()
        for part in [tableScroll, gridBox] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            area.addSubview(part)
            NSLayoutConstraint.activate([
                part.topAnchor.constraint(equalTo: area.topAnchor),
                part.bottomAnchor.constraint(equalTo: area.bottomAnchor),
                part.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                part.trailingAnchor.constraint(equalTo: area.trailingAnchor)
            ])
        }
        return area
    }

    /// Puts the list of the current view on screen. The keyboard goes with it.
    func applyViewMode() {
        guard isViewLoaded else { return }
        let responder = view.window?.firstResponder
        let hadKeyboard = responder === tableView || responder === gridView
        tableView.enclosingScrollView?.isHidden = showsGrid
        sortHeader.superview?.isHidden = !showsGrid
        if hadKeyboard { view.window?.makeFirstResponder(listView) }
        // The list that comes up was scrolled for another set of rows (or never); it follows the cursor.
        shownCursor = nil
        needsFullReload = true
        redraw()
    }

    /// Takes the entries from the model again, in the list that is on screen. With `full`
    /// false the table keeps the rows it has made and only brings them up to date: the same
    /// folder was read again, sorted or filtered, and throwing every row view away to make
    /// it anew is most of what a redraw would cost.
    func reloadList(full: Bool = true) {
        gridMarks = [:]
        if showsGrid {
            gridView.reload(flow: viewMode == .brief ? .columns : .rows)
            gridDidScroll()
        } else {
            syncing = true
            // The table keeps the rows it has made wherever it can: making the rows on screen
            // anew is what a redraw costs (some 50 ms a time, measured with a full window),
            // whereas being told of more rows costs it next to nothing, and of fewer rows about
            // a tenth of a microsecond for each that went. Only when so many rows go at once
            // that this adds up to more than making the visible ones anew is the list taken anew.
            let removed = tableView.numberOfRows - model.rowCount
            if full || removed > PanelViewController.rowsRemovedInPlace {
                tableView.reloadData()
            } else {
                tableView.noteNumberOfRowsChanged()
                refreshRows()
            }
            syncing = false
        }
    }

    /// Brings every row the table has made up to date with the model, where it stands: a cell
    /// is touched only if what it shows differs, so a list that did not change costs a
    /// comparison per cell on screen and nothing is laid out or drawn.
    func refreshRows() {
        let ownIcons = model.volume?.isLocal ?? false
        let columns = tableView.tableColumns
        tableView.enumerateAvailableRowViews { rowView, row in
            let item = model.item(atRow: row)
            let color = rowNameColor(for: item, selected: model.isSelected(row: row))
            for index in columns.indices {
                guard let cell = rowView.view(atColumn: index) as? NSTableCellView else { continue }
                fill(cell, of: columns[index], row: row, item: item, color: color, ownIcons: ownIcons)
            }
        }
    }

    /// Redraws the visible rows and the status line after the selection or a folder size changed.
    func redrawSelection() {
        if showsGrid {
            // Only the cells whose mark differs from the way they were drawn.
            var marks: [Int: Bool] = [:]
            for row in gridView.visibleRows {
                let marked = model.isSelected(row: row)
                marks[row] = marked
                if gridMarks[row] != marked { gridView.redraw(row: row) }
            }
            gridMarks = marks
        } else {
            // Only the cells whose colour or text differs from what they show.
            refreshRows()
        }
        updateStatus()
    }

    /// The own icons of these files have arrived: the rows on screen that show them take them.
    func iconsArrived(for paths: Set<String>) {
        guard isViewLoaded, model.directory.isFileURL || model.volume?.isLocal == true else { return }
        if showsGrid {
            for row in gridView.visibleRows {
                if let item = model.item(atRow: row), item.url.isFileURL, paths.contains(item.url.path) {
                    gridView.redraw(row: row)
                }
            }
        } else {
            refreshRows()
        }
    }

    /// Puts the cursor of the list where the model's is. The list scrolls to it when the cursor
    /// is on another item than the last time (or in another folder or tab), and when `forceScroll`
    /// says the cursor was moved; a list whose contents merely changed (a refresh, another piece
    /// of the folder arriving) stays where the user has scrolled it.
    func showCursor(forceScroll: Bool = false) {
        guard model.rowCount > 0 else {
            shownCursor = nil
            shownCursorRow = nil
            return
        }
        let row = max(0, min(model.cursor, model.rowCount - 1))
        model.cursor = row
        let shown = (tab: ObjectIdentifier(model), name: model.cursorItem?.name)
        let moved = shownCursor.map { $0.tab != shown.tab || $0.name != shown.name } ?? true
        let oldRow = shownCursorRow
        shownCursor = shown
        shownCursorRow = row
        if showsGrid {
            // The cells the cursor leaves and enters, nothing else.
            if let oldRow, oldRow != row { gridView.redraw(row: oldRow) }
            gridView.redraw(row: row)
            if moved || forceScroll { gridView.scrollRowToVisible(row) }
        } else {
            syncing = true
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            syncing = false
            if moved || forceScroll { tableView.scrollRowToVisible(row) }
        }
    }

    // MARK: The grid's cursor

    /// A plain click on a row of the grid: the cursor goes there.
    func clicked(row: Int) {
        model.moveCursor(to: row)
    }

    /// An arrow key in the grid.
    func moveCursor(_ direction: GridGeometry.Direction) {
        guard showsGrid else { return }
        model.moveCursor(to: gridView.geometry.index(from: model.cursor, moving: direction))
    }

    /// A key that types something was pressed in the list and is bound to nothing: it goes on
    /// looking for a file whose name starts with what was typed (spec 03 › Quick search).
    func typeToFind(_ characters: String, at time: TimeInterval) {
        moveCursor(toNameStartingWith: typeSelect.add(characters, at: time))
    }

    /// Finding a file by typing, in every view. A short list is looked through here; a long
    /// one in the background, so a key costs the main thread nothing however long the list is,
    /// and only the search for the last key typed moves the cursor.
    func moveCursor(toNameStartingWith prefix: String) {
        let tab = model
        let offset = tab.hasParentRow ? 1 : 0
        let (items, cursor) = (tab.items, tab.cursor - offset)
        typeFind?.cancel()
        typeFind = nil
        guard items.count >= PanelViewController.backgroundSortThreshold else {
            if let index = TypeSelect.row(matching: prefix, in: items, from: cursor) {
                tab.moveCursor(to: index + offset)
            }
            return
        }
        let (flag, version) = (CancellationFlag(), tab.shownVersion)
        typeFind = flag
        Background.compute(
            work: { TypeSelect.row(matching: prefix, in: items, from: cursor, cancellation: flag) },
            then: { [weak self] index in
                guard let self, self.typeFind === flag else { return }
                self.typeFind = nil
                // The list the rows were counted in is still the one on screen.
                guard self.model === tab, tab.shownVersion == version, let index else { return }
                tab.moveCursor(to: index + offset)
            })
    }

    /// The grid shows other rows now: the pictures of those that went out of sight are no
    /// longer wanted.
    func gridDidScroll() {
        // The cells that come into view are drawn from the model, whatever was noted before.
        gridMarks = [:]
        guard viewMode == .thumbnails else { return thumbnails.keepOnly([]) }
        let side = settings.thumbnailSide
        thumbnails.keepOnly(
            Set(
                gridView.visibleRows.compactMap { model.item(atRow: $0) }.map {
                    ThumbnailStore.key(for: $0, side: side)
                }))
    }

    func thumbnailArrived(for name: String) {
        guard viewMode == .thumbnails else { return }
        // The tile may have been scrolled out of sight (or not be placed yet) since it was asked for.
        if let row = gridView.visibleRows.first(where: { model.item(atRow: $0)?.name == name })
            ?? model.row(ofName: name)
        {
            gridView.redraw(row: row)
        }
    }

    // MARK: Colours

    /// The colour a name is drawn in, the same in every view: marked items in the mark colour,
    /// then the colours by file type, hidden items dimmed
    /// (spec 03 › Cursor, selection and row states, 03 › Colours by file type).
    func nameColor(for item: FileItem?, selected: Bool) -> NSColor {
        if selected { return .systemRed }
        guard let item else { return .labelColor }
        if !settings.colorRules.isEmpty, let color = ColorRule.color(for: item.name, in: settings.colorRules) {
            return color
        }
        return item.isHidden ? .secondaryLabelColor : .labelColor
    }

    /// `nameColor` for the cells of the table: the table asks for every column of a row in a
    /// row, so the colour rules are looked at once per row and not once per column.
    func rowNameColor(for item: FileItem?, selected: Bool) -> NSColor {
        if let memo = rowColor, memo.name == item?.name, memo.hidden == (item?.isHidden ?? false),
            memo.selected == selected
        {
            return memo.color
        }
        let color = nameColor(for: item, selected: selected)
        rowColor = (item?.name, item?.isHidden ?? false, selected, color)
        return color
    }

    // MARK: Columns of the Full view

    /// Shows the plugin columns of `extraColumns` after the standard ones. An id no plugin
    /// offers (its plugin is not there) is kept in the list but shows nothing.
    func rebuildExtraColumns() {
        guard isViewLoaded else { return }
        rememberColumnWidths()
        for column in tableView.tableColumns
        where column.identifier.rawValue.hasPrefix(PanelViewController.extraColumnPrefix) {
            tableView.removeTableColumn(column)
        }
        var shown: Set<String> = []
        for id in extraColumns where shown.insert(id).inserted {
            guard let column = kernel.columns[id] else { continue }
            let identifier = PanelViewController.extraColumnPrefix + id
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            tableColumn.title = column.title
            tableColumn.width = CGFloat(columnWidths[identifier] ?? Double(column.width))
            tableColumn.minWidth = 30
            tableColumn.resizingMask = .userResizingMask
            if column.alignsRight { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        if !showsGrid { reloadList() }
    }

    /// Notes the widths the columns have now, so they can be remembered.
    func rememberColumnWidths() {
        guard isViewLoaded else { return }
        for column in tableView.tableColumns { columnWidths[column.identifier.rawValue] = Double(column.width) }
    }

    /// The plugin column a table column stands for.
    private func contentColumn(of tableColumn: NSTableColumn) -> ContentColumn? {
        let identifier = tableColumn.identifier.rawValue
        guard identifier.hasPrefix(PanelViewController.extraColumnPrefix) else { return nil }
        return kernel.columns[String(identifier.dropFirst(PanelViewController.extraColumnPrefix.count))]
    }

    /// Values of plugin columns were computed: the rows on screen that show them are drawn again.
    func columnValuesArrived(for names: Set<String>) {
        guard !showsGrid else { return }
        let columns = IndexSet(
            tableView.tableColumns.indices.filter {
                tableView.tableColumns[$0].identifier.rawValue.hasPrefix(PanelViewController.extraColumnPrefix)
            })
        let visible = tableView.rows(in: tableView.visibleRect)
        let rows = IndexSet(
            (visible.location..<(visible.location + visible.length)).filter { row in
                model.item(atRow: row).map { names.contains($0.name) } ?? false
            })
        if !rows.isEmpty, !columns.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: columns) }
    }

    /// What the panel remembers of its looks between sessions.
    var viewState: PanelViewState {
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

    // MARK: Header

    /// A click on a column header: the column's sort command, or Reversed Order when the list
    /// is already sorted by that column (spec 03 › Header clicks).
    func headerClicked(_ column: FileListColumn) {
        guard let key = column.sortKey, let command = column.sortCommand else { return }
        performFocused(key == model.wantedSort.key ? .reversedOrder : command)
    }

    /// The menu of the column header: the views, the plugin columns to show or hide, and the
    /// dialog for them (spec 05 › Column header). It acts on this panel, which becomes the source.
    func fillHeaderMenu() {
        focus()
        headerMenu.removeAllItems()
        let views = MenuBuilder.menu(
            "", [.viewBrief, .viewFull, .viewThumbnails], commands: commands, keys: kernel.keyBindings)
        for item in views.items {
            views.removeItem(item)
            item.state = commands.isChecked(MenuBuilder.command(of: item) ?? "") ? .on : .off
            headerMenu.addItem(item)
        }
        if !kernel.columns.all.isEmpty, !headerMenu.items.isEmpty { headerMenu.addItem(.separator()) }
        for column in kernel.columns.all {
            let item = headerMenu.addItem(
                withTitle: column.title, action: #selector(extraColumnChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.id
            item.state = extraColumns.contains(column.id) ? .on : .off
        }
        if let configure = commands[PanelShellCommands.customColumns] {
            headerMenu.addItem(.separator())
            headerMenu.addItem(MenuBuilder.item(configure, keys: kernel.keyBindings))
        }
    }

    @objc func extraColumnChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        toggleExtraColumn(id)
    }

    /// Shows a plugin column that is hidden, at the end, and hides one that is shown.
    func toggleExtraColumn(_ id: String) {
        if extraColumns.contains(id) {
            extraColumns.removeAll { $0 == id }
        } else {
            extraColumns.append(id)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }

    /// Row views are used again like cells: scrolling and reloading would otherwise make one
    /// for every row that comes into sight.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(withIdentifier: CursorRowView.reuseIdentifier, owner: nil) as? CursorRowView
        {
            reused.panel = self
            return reused
        }
        let rowView = CursorRowView()
        rowView.identifier = CursorRowView.reuseIdentifier
        rowView.panel = self
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, tableView.selectedRow >= 0 else { return }
        model.cursor = tableView.selectedRow
        host?.panelCursorDidChange(self)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        if let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) { headerClicked(column) }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        // Widths are written down when the program quits and when the columns change; a drag
        // of a column border would otherwise save on every point of its way.
        rememberColumnWidths()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let item = model.item(atRow: row)
        let color = rowNameColor(for: item, selected: model.isSelected(row: row))
        let cell: NSTableCellView
        if let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) {
            cell =
                tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView
                ?? column.makeCell()
        } else if contentColumn(of: tableColumn) != nil {
            cell =
                tableView.makeView(withIdentifier: FileListColumn.extraCellIdentifier, owner: nil) as? NSTableCellView
                ?? FileListColumn.makeExtraCell()
        } else {
            return nil
        }
        fill(cell, of: tableColumn, row: row, item: item, color: color, ownIcons: model.volume?.isLocal ?? false)
        return cell
    }

    /// Makes a cell show its row; used for a cell that is new or used again and for one that
    /// stays where it is (`refreshRows`). Nothing is set that is already so.
    private func fill(
        _ cell: NSTableCellView, of tableColumn: NSTableColumn, row: Int, item: FileItem?, color: NSColor,
        ownIcons: Bool
    ) {
        if let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) {
            column.fill(cell, with: item, color: color, ownIcons: ownIcons)
            // The rename box stands in for the name and the extension of its row.
            if column == .name || column == .ext {
                let isHidden = row == renamingRow
                if cell.textField?.isHidden != isHidden { cell.textField?.isHidden = isHidden }
            }
            return
        }
        guard let column = contentColumn(of: tableColumn), let field = cell.textField else { return }
        let alignment: NSTextAlignment = column.alignsRight ? .right : .left
        if field.alignment != alignment { field.alignment = alignment }
        if field.textColor != color { field.textColor = color }
        // A value that is not known yet is on its way; the cell is filled in when it arrives.
        let text = DisplayText.clean(item.flatMap { columnValues.text(of: column, for: $0) } ?? "")
        if field.stringValue != text { field.stringValue = text }
    }
}
