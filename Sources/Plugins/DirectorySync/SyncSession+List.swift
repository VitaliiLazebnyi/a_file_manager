import AFMKernel
import Foundation

/// The list: the rows filtered by the Show buttons, sorted inside each folder, with the folders' captions.
extension SyncSession {
    /// The list as it is shown, worked out from the rows alone (so it can be made on any thread).
    internal struct Layout {
        /// The captions and rows in the order shown.
        internal var entries: [SyncListEntry] = []
        /// The position in `entries` of each row, -1 for a row that is not shown.
        internal var positions: [Int] = []
        /// The positions of the captions in `entries`, in order.
        internal var headerPositions: [Int] = []
        /// How many of the shown rows have an action that the plan would carry out.
        internal var actionableCount = 0
        /// The counts of all the rows.
        internal var summary = SyncSummary([])
    }

    /// The rows shown, as indexes into `rows`, in the order shown.
    internal var visibleRows: [Int] {
        entries.compactMap { entry in
            if case .row(let index) = entry {
                return index
            }
            return nil
        }
    }

    /// Whether Synchronize can start: the rows of a whole comparison are shown and some row has an action.
    internal var canSynchronize: Bool { phase == .compared && actionableCount > 0 && !isPartial && !isPlanning }

    /// The list as it is shown now.
    internal var currentLayout: Layout {
        Layout(
            entries: entries,
            positions: positions,
            headerPositions: headerPositions,
            actionableCount: actionableCount,
            summary: summary
        )
    }

    /// Whether the plan would carry out the row's action.
    nonisolated internal static func isActionable(_ row: SyncRow) -> Bool {
        row.action != .nothing && row.accepts(row.action)
    }

    /// Filters by the Show buttons, sorts inside each subdirectory and puts the captions in.
    nonisolated internal static func layout(rows: [SyncRow], show: SyncShow, sort: SyncSort) -> Layout {
        var layout = Layout()
        let (order, groups) = groupedByFolder(rows, show: show)
        layout.entries.reserveCapacity(rows.count + groups.count)
        for (group, directory) in order.enumerated() {
            if !directory.isEmpty {
                layout.entries.append(.header(directory))
            }
            layout.entries += sorted(groups[group], rows: rows, by: sort).map(SyncListEntry.row)
        }
        layout.positions = [Int](repeating: -1, count: rows.count)
        for (position, entry) in layout.entries.enumerated() {
            switch entry {
            case .header:
                layout.headerPositions.append(position)

            case .row(let index):
                layout.positions[index] = position
                if isActionable(rows[index]) {
                    layout.actionableCount += 1
                }
            }
        }
        layout.summary = SyncSummary(rows)
        return layout
    }

    /// The folders of the rows the Show buttons let through, in the order they first come, each with its rows.
    nonisolated private static func groupedByFolder(_ rows: [SyncRow], show: SyncShow) -> (
        order: [String], groups: [[Int]]
    ) {
        // The comparison delivers the rows grouped by folder, so a row mostly belongs to the group of the one
        // before.
        var order: [String] = []
        var groups: [[Int]] = []
        var groupOf: [String: Int] = [:]
        var current = -1
        var currentDirectory: String?
        for index in rows.indices where show.shows(rows[index]) {
            let directory = rows[index].directory
            if directory != currentDirectory {
                if let known = groupOf[directory] {
                    current = known
                } else {
                    current = groups.count
                    groupOf[directory] = current
                    order.append(directory)
                    groups.append([])
                }
                currentDirectory = directory
            }
            groups[current].append(index)
        }
        return (order, groups)
    }

    /// Orders the rows of one folder.
    ///
    /// The keys (a size, a date) are taken out once, and the pairs of key and row are sorted:
    /// sorting the rows by looking into their files on every comparison takes seconds at a million.
    nonisolated private static func sorted(_ indexes: [Int], rows: [SyncRow], by sort: SyncSort) -> [Int] {
        // The comparison delivers the rows by name already.
        if sort.key == .name {
            return sort.ascending ? indexes : indexes.reversed()
        }
        func key(_ index: Int) -> Int64 {
            let row = rows[index]
            guard let item = sort.side == .left ? row.left ?? row.right : row.right ?? row.left else {
                return 0
            }
            return sort.key == .size ? item.size : Int64((item.modified.timeIntervalSince1970 * 1_000_000).rounded())
        }
        let ordered = indexes.map { index in (key: key(index), index: index) }
            .sorted { first, second in (first.key, first.index) < (second.key, second.index) }
            .map(\.index)
        return sort.ascending ? ordered : ordered.reversed()
    }

    /// Lays the list out again.
    ///
    /// The rows of a large list are worked on away from the main thread, and the previous list
    /// stays on show until the new one has come; where the rows themselves are new (`rowsChanged`)
    /// there is nothing to show meanwhile.
    internal func rebuild(rowsChanged: Bool) {
        layoutGeneration += 1
        let generation = layoutGeneration
        if rowsChanged {
            entries = []
            positions = []
            headerPositions = []
            actionableCount = 0
        }
        if runsInline || rows.count < worksInBackgroundFrom {
            apply(Self.layout(rows: rows, show: show, sort: sort), recount: false)
            return
        }
        let epoch = actionEpoch
        if phase == .compared {
            status = "Preparing the list of \(rows.count) files…"
        }
        changed()
        // The list as it is now: the rows and the choices may change while the layout is made.
        let listed = rows
        let shown = show
        let order = sort
        startWorker("Synchronize directories: list") { [weak self] in
            let layout = Self.layout(rows: listed, show: shown, sort: order)
            DispatchQueue.main.async { [weak self] in
                guard let self, layoutGeneration == generation else {
                    return
                }
                // Actions set while the list was made are counted again.
                apply(layout, recount: actionEpoch != epoch)
            }
        }
    }

    /// Shows a layout; with `recount` its actionable rows are counted again, from the actions as they are now.
    internal func apply(_ layout: Layout, recount: Bool) {
        entries = layout.entries
        positions = layout.positions
        headerPositions = layout.headerPositions
        actionableCount = layout.actionableCount
        summary = layout.summary
        if recount {
            actionableCount = entries.reduce(0) { count, entry in
                if case .row(let index) = entry, rows.indices.contains(index), Self.isActionable(rows[index]) {
                    return count + 1
                }
                return count
            }
        }
        if phase == .compared || phase == .synchronizing {
            let shown = entries.count - headerPositions.count
            let hidden = rows.count - shown
            status =
                (isPartial ? "Cancelled: the list is incomplete. " : "") + summary.text
                + (hidden > 0 ? "   [\(shown) shown, \(hidden) hidden by the Show buttons]" : "")
        }
        changed()
    }

    /// The subdirectory indicator next to the Show buttons: `6/9 dups/sub`
    /// (spec 09 › Result list).
    internal func groupIndicator(atEntry position: Int) -> String {
        guard !headerPositions.isEmpty else {
            return ""
        }
        // The last caption at or before the position, found by bisection.
        var low = 0
        var high = headerPositions.count
        while low < high {
            let middle = (low + high) / 2
            if headerPositions[middle] <= position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let current = low > 0 ? low - 1 : nil
        var name = ""
        if let current, case .header(let text) = entries[headerPositions[current]] {
            name = text
        }
        return "\(current.map { index in index + 1 } ?? 0)/\(headerPositions.count) \(name)"
    }

    /// The entry of the next or previous subdirectory caption, for Ctrl+PgDn / Ctrl+PgUp.
    internal func header(after position: Int, forward: Bool) -> Int? {
        forward
            ? headerPositions.first { header in header > position }
            : headerPositions.last { header in header < position }
    }
}
