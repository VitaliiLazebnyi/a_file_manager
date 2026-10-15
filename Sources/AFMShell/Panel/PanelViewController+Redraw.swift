import AFMContracts
import AFMKernel
import AppKit

/// Drawing the panel from the active tab: the list, the bars around it and the status line
/// (spec 03 › Status line).
extension PanelViewController {
    /// `5 k / 8 k in 4 / 14 file(s), 0 / 2 dir(s)` (spec 03 › Status line). While a directory
    /// is still arriving, the line says so and counts what has come (`itemsSoFar`); while a
    /// remembered listing is read afresh, it says that (`refreshing`).
    internal static func statusText(_ totals: PanelModel.Totals, itemsSoFar: Int?, refreshing: Bool) -> String {
        var text =
            "\(Format.kilobytes(totals.selectedBytes)) / \(Format.kilobytes(totals.totalBytes)) in "
            + "\(totals.selectedFiles) / \(totals.totalFiles) file(s)"
        if totals.totalFolders > 0 {
            text += ", \(totals.selectedFolders) / \(totals.totalFolders) dir(s)"
        }
        if let itemsSoFar {
            text = "Loading… \(Format.bytes(Int64(itemsSoFar))) items so far   " + text
        }
        if refreshing {
            text = "Refreshing…   " + text
        }
        return text
    }

    /// `win  ini  34 10/11/2026 01:19 rw-r--r--`: the item under the cursor, as the status line
    /// of the Brief view shows it (spec 03 › Status line).
    internal static func detailText(for item: FileItem) -> String {
        let name = DisplayText.clean(item.isFolder ? "[\(item.name)]" : item.baseName)
        return [
            name, DisplayText.clean(item.ext), FileListColumn.size.text(for: item), FileListColumn.date.text(for: item),
            FileListColumn.attr.text(for: item)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "  ")
    }

    /// Redraws everything from the active tab.
    internal func redraw() {
        guard isViewLoaded else {
            return
        }
        // The in-place editor stays with its item for as long as that is in the list.
        keepRenameIfItemRemains()
        shownTab = model
        // What is kept of a folder's files is of no use for another folder.
        let location = "\(ObjectIdentifier(model).hashValue) \(model.directory.locationKey)"
        let isAnotherView = needsFullReload
        if location != storedLocation {
            storedLocation = location
            columnValues.reset(folder: model.directory)
            thumbnails.reset()
            // Another folder starts at its cursor.
            shownCursor = nil
        }
        needsFullReload = false
        // Other entries, of the same folder or of another, are brought into the rows the
        // table has: only another view or other columns make it take the list anew.
        reloadList(full: isAnotherView)
        showCursor(forceScroll: false)
        placeRenameField()
        updatePathBar()
        showQuickFilterBar()
        tabBar.update(
            titles: tabs.tabs.indices.map { DisplayText.clean(tabs.title(at: $0)) },
            paths: tabs.tabs.map { DisplayText.clean(kernel.fileSystems.displayPath($0.directory)) },
            active: tabs.activeIndex
        )
        updateDriveLine()
        updateSortIndicators()
        updateStatus()
    }

    /// Writes the status line: the figures of the list, what the Brief view does not show of
    /// the cursor's item, the quick filter, and whether the folder is still arriving.
    internal func updateStatus() {
        guard isViewLoaded else {
            return
        }
        if model.isOpening {
            statusLabel.stringValue = "Reading \(DisplayText.clean(kernel.fileSystems.displayPath(model.directory)))…"
        } else if model.isRefreshing {
            statusLabel.stringValue = Self.statusText(model.totals, itemsSoFar: nil, refreshing: true)
        } else if viewMode == .brief, model.isComplete, model.selectionCount == 0, let item = model.cursorItem {
            // In the Brief view the line tells what the list does not show (spec 03 › Status line).
            statusLabel.stringValue = Self.detailText(for: item)
        } else {
            // The model keeps the figures as it goes, so asking costs nothing here.
            let itemsSoFar = model.isComplete ? nil : model.items.count
            statusLabel.stringValue = Self.statusText(model.totals, itemsSoFar: itemsSoFar, refreshing: false)
        }
        if let text = quickFilterText, !text.isEmpty {
            statusLabel.stringValue += "   ⏷ Filter: \(text)"
        }
        // The wheel turns for as long as the folder on screen is not all there.
        showsActivity = isLoading && !model.isComplete
        if showsActivity {
            activityIndicator.startAnimation(nil)
        } else {
            activityIndicator.stopAnimation(nil)
        }
    }

    /// The drive button and the free space of the volume the folder is on.
    private func updateDriveLine() {
        volumeButton.setTitle(DisplayText.clean(model.volume?.name ?? model.directory.scheme ?? "/"))
        if let free = model.volume?.freeBytes, let total = model.volume?.totalBytes {
            freeLabel.stringValue = "\(Format.shortSize(free)) of \(Format.shortSize(total)) free"
        } else {
            freeLabel.stringValue = ""
        }
    }

    /// The arrow of the sort key in the table's header and in the grid's.
    private func updateSortIndicators() {
        for tableColumn in tableView.tableColumns {
            let key = FileListColumn(rawValue: tableColumn.identifier.rawValue)?.sortKey
            let indicator = model.wantedSort.descending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator"
            tableView.setIndicatorImage(key == model.wantedSort.key ? NSImage(named: indicator) : nil, in: tableColumn)
        }
        sortHeader.order = model.wantedSort
    }
}
