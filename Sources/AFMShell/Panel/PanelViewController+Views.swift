import AFMContracts
import AFMKernel
import AppKit

/// The parts of a panel that differ by view: which list is on screen, how the cursor is shown
/// in it, finding by typing, and the colours of names (spec 03 › View types).
extension PanelViewController {
    /// Up to this many rows fewer at once, the table is told the new number and keeps its rows.
    internal static let rowsRemovedInPlace = 400_000

    /// True while the Brief or the Thumbnails view is on screen.
    internal var showsGrid: Bool { viewMode != .full }

    /// The list that is on screen; it has the keyboard when the panel is the source.
    internal var listView: NSView { showsGrid ? gridView : tableView }

    /// Puts the list of the current view on screen. The keyboard goes with it.
    internal func applyViewMode() {
        guard isViewLoaded else {
            return
        }
        let responder = view.window?.firstResponder
        let hadKeyboard = responder === tableView || responder === gridView
        tableView.enclosingScrollView?.isHidden = showsGrid
        sortHeader.superview?.isHidden = !showsGrid
        if hadKeyboard {
            view.window?.makeFirstResponder(listView)
        }
        // The list that comes up was scrolled for another set of rows (or never); it follows the cursor.
        shownCursor = nil
        needsFullReload = true
        redraw()
    }

    /// Takes the entries from the model again, in the list that is on screen. With `full`
    /// false the table keeps the rows it has made and only brings them up to date: the same
    /// folder was read again, sorted or filtered, and throwing every row view away to make
    /// it anew is most of what a redraw would cost.
    internal func reloadList(full: Bool) {
        gridMarks = [:]
        guard !showsGrid else {
            gridView.reload(flow: viewMode == .brief ? .columns : .rows)
            gridDidScroll()
            return
        }
        syncing = true
        // The table keeps the rows it has made wherever it can: making the rows on screen
        // anew is what a redraw costs (some 50 ms a time, measured with a full window),
        // whereas being told of more rows costs it next to nothing, and of fewer rows about
        // a tenth of a microsecond for each that went. Only when so many rows go at once
        // that this adds up to more than making the visible ones anew is the list taken anew.
        let removed = tableView.numberOfRows - model.rowCount
        if full || removed > Self.rowsRemovedInPlace {
            tableView.reloadData()
        } else {
            tableView.noteNumberOfRowsChanged()
            refreshRows()
        }
        syncing = false
    }

    /// Redraws the visible rows and the status line after the selection or a folder size changed.
    internal func redrawSelection() {
        if showsGrid {
            // Only the cells whose mark differs from the way they were drawn.
            var marks: [Int: Bool] = [:]
            for row in gridView.visibleRows {
                let marked = model.isSelected(row: row)
                marks[row] = marked
                if gridMarks[row] != marked {
                    gridView.redraw(row: row)
                }
            }
            gridMarks = marks
        } else {
            // Only the cells whose colour or text differs from what they show.
            refreshRows()
        }
        updateStatus()
    }

    /// The own icons of these files have arrived: the rows on screen that show them take them.
    internal func iconsArrived(for paths: Set<String>) {
        guard isViewLoaded, model.directory.isFileURL || model.volume?.isLocal == true else {
            return
        }
        guard showsGrid else {
            refreshRows()
            return
        }
        for row in gridView.visibleRows {
            if let item = model.item(atRow: row), item.url.isFileURL, paths.contains(item.url.path) {
                gridView.redraw(row: row)
            }
        }
    }

    /// Puts the cursor of the list where the model's is. The list scrolls to it when the cursor
    /// is on another item than the last time (or in another folder or tab), and when `forceScroll`
    /// says the cursor was moved; a list whose contents merely changed (a refresh, another piece
    /// of the folder arriving) stays where the user has scrolled it.
    internal func showCursor(forceScroll: Bool) {
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
            if let oldRow, oldRow != row {
                gridView.redraw(row: oldRow)
            }
            gridView.redraw(row: row)
            if moved || forceScroll {
                gridView.scrollRowToVisible(row)
            }
        } else {
            syncing = true
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            syncing = false
            if moved || forceScroll {
                tableView.scrollRowToVisible(row)
            }
        }
    }

    /// A plain click on a row of the grid: the cursor goes there.
    internal func clicked(row: Int) {
        model.moveCursor(to: row)
    }

    /// An arrow key in the grid.
    internal func moveCursor(_ direction: GridGeometry.Direction) {
        guard showsGrid else {
            return
        }
        model.moveCursor(to: gridView.geometry.index(from: model.cursor, moving: direction))
    }

    /// A key that types something was pressed in the list and is bound to nothing: it goes on
    /// looking for a file whose name starts with what was typed, at `time` (the event's)
    /// (spec 03 › Quick search).
    internal func typeToFind(_ characters: String, at time: TimeInterval) {
        moveCursor(toNameStartingWith: typeSelect.add(characters, at: time))
    }

    /// Finding a file by typing, in every view. A short list is looked through here; a long
    /// one in the background, so a key costs the main thread nothing however long the list is,
    /// and only the search for the last key typed moves the cursor.
    internal func moveCursor(toNameStartingWith prefix: String) {
        let tab = model
        let offset = tab.hasParentRow ? 1 : 0
        let (items, cursor) = (tab.items, tab.cursor - offset)
        typeFind?.cancel()
        typeFind = nil
        guard items.count >= Self.backgroundSortThreshold else {
            if let index = TypeSelect.row(matching: prefix, in: items, from: cursor, cancellation: nil) {
                tab.moveCursor(to: index + offset)
            }
            return
        }
        let (flag, version) = (CancellationFlag(), tab.shownVersion)
        typeFind = flag
        Background.compute(
            work: { TypeSelect.row(matching: prefix, in: items, from: cursor, cancellation: flag) },
            then: { [weak self] index in
                guard let self, typeFind === flag else {
                    return
                }
                typeFind = nil
                // The list the rows were counted in is still the one on screen.
                guard model === tab, tab.shownVersion == version, let index else {
                    return
                }
                tab.moveCursor(to: index + offset)
            }
        )
    }

    /// The grid shows other rows now: the pictures of those that went out of sight are no
    /// longer wanted.
    internal func gridDidScroll() {
        // The cells that come into view are drawn from the model, whatever was noted before.
        gridMarks = [:]
        guard viewMode == .thumbnails else {
            thumbnails.keepOnly([])
            return
        }
        let side = settings.thumbnailSide
        let visible = gridView.visibleRows.compactMap { model.item(atRow: $0) }
        thumbnails.keepOnly(Set(visible.map { ThumbnailStore.key(for: $0, side: side) }))
    }

    /// The picture of the entry `name` has arrived: its tile is drawn again.
    internal func thumbnailArrived(for name: String) {
        guard viewMode == .thumbnails else {
            return
        }
        // The tile may have been scrolled out of sight (or not be placed yet) since it was asked for.
        if let row = gridView.visibleRows.first(where: { model.item(atRow: $0)?.name == name }) ?? model.row(ofName: name) {
            gridView.redraw(row: row)
        }
    }

    /// The colour a name is drawn in, the same in every view: marked items in the mark colour,
    /// then the colours by file type, hidden items dimmed
    /// (spec 03 › Cursor, selection and row states, 03 › Colours by file type).
    internal func nameColor(for item: FileItem?, selected: Bool) -> NSColor {
        if selected {
            return .systemRed
        }
        guard let item else {
            return .labelColor
        }
        if !settings.colorRules.isEmpty, let color = ColorRule.color(for: item.name, in: settings.colorRules) {
            return color
        }
        return item.isHidden ? .secondaryLabelColor : .labelColor
    }

    /// `nameColor` for the cells of the table: the table asks for every column of a row in a
    /// row, so the colour rules are looked at once per row and not once per column.
    internal func rowNameColor(for item: FileItem?, selected: Bool) -> NSColor {
        if let memo = rowColor, memo.name == item?.name, memo.isHidden == (item?.isHidden ?? false),
            memo.isSelected == selected
        {
            return memo.color
        }
        let color = nameColor(for: item, selected: selected)
        rowColor = PanelRowColor(name: item?.name, isHidden: item?.isHidden ?? false, isSelected: selected, color: color)
        return color
    }
}
