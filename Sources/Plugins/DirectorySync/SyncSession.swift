import AFMContracts
import AFMKernel
import Foundation

/// A line of the result list as it is shown: the grey caption of a subdirectory, or a row.
internal enum SyncListEntry: Equatable {
    case header(String)
    /// The index into `SyncSession.rows`.
    case row(Int)
}

internal enum SyncSortKey: Int, Codable {
    case name, size, date
}

internal enum SyncSide {
    case left, right
}

/// The settings keys of Synchronize directories, all below `directorySync.`.
internal enum SyncSettingsKey {
    internal static let scope = "directorySync"
    internal static let options = "options"
    internal static let show = "show"
    internal static let sets = "sets"
    internal static let recompare = "recompareAfterSync"
    internal static let confirmOverwrites = "confirmOverwrites"
    internal static let useTrash = "useTrash"
    internal static let changeSourceDates = "changeSourceDates"
    internal static let warnReadErrors = "warnReadErrors"
}

/// Everything the Synchronize directories window does, without the window: the two paths, the
/// options, the rows of the last comparison with the actions the user chose, and the run
/// (spec 09 › Synchronize directories).
///
/// The window draws this and forwards clicks and keys.
///
/// **Threading.** The session belongs to the main thread. A comparison runs on a background
/// queue and comes back to the main thread with its rows; while it runs, only its
/// cancellation flag is touched from here. Synchronizing runs as a job of the kernel's job
/// service, with the progress window. With `runsInline` (tests) the comparison runs on the
/// calling thread instead.
@MainActor
internal final class SyncSession {
    internal enum Phase {
        /// `synchronizing`: the job that carries out the plan runs; neither Compare nor Synchronize may start.
        case idle, comparing, compared, synchronizing
    }

    /// The list as it is shown, worked out from the rows alone (so it can be made on any thread).
    internal struct Layout {
        internal var entries: [SyncListEntry] = []
        internal var positions: [Int] = []
        internal var headerPositions: [Int] = []
        internal var actionableCount = 0
        internal var summary = SyncSummary([])
    }
    /// Rows from this many on are laid out and planned away from the main thread.
    internal static let backgroundFrom = 20_000

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    private let settings: any SettingsStore

    internal var leftPath = ""
    internal var rightPath = ""
    internal var options: SyncOptions
    internal var show: SyncShow { didSet { rebuild(rowsChanged: false) } }
    internal var sort: (key: SyncSortKey, side: SyncSide, ascending: Bool) = (.name, .left, true) {
        didSet { rebuild(rowsChanged: false) }
    }
    /// "Only selected (in main window)".
    internal var onlySelected = false
    /// The names that were selected in the two panels when the window was opened.
    internal private(set) var selectedNames: [String] = []
    internal var runsInline = false
    /// Called on the main thread whenever something the window shows has changed.
    internal var onChange: () -> Void = {}
    /// Called instead of `onChange` when only the actions of these rows (indexes into `rows`)
    /// changed, so that the window redraws just them.
    internal var onRowsChange: (([Int]) -> Void)?

    internal private(set) var rows: [SyncRow] = []
    internal private(set) var entries: [SyncListEntry] = []
    /// The position in `entries` of each row, -1 for a row that is not shown.
    internal private(set) var positions: [Int] = []
    /// The positions of the captions in `entries`, in order.
    private var headerPositions: [Int] = []
    /// How many of the shown rows have an action that the plan would carry out.
    private var actionableCount = 0
    internal private(set) var phase = Phase.idle
    internal private(set) var status = "Please press 'Compare' to start"
    /// 0…1 while files are compared by content.
    internal private(set) var fraction: Double?
    /// The files picked with "Select for comparison", one per side.
    internal private(set) var picked: (left: URL?, right: URL?) = (nil, nil)

    internal private(set) var base = URL(fileURLWithPath: "/")
    /// The two directories of the last finished comparison; what they are counts only once it
    /// has finished (`phase` is `.compared` or `.synchronizing`).
    private var roots = (left: URL(fileURLWithPath: "/"), right: URL(fileURLWithPath: "/"))
    private var running: SyncComparison?
    /// What the last finished comparison used and found, for what is done with its rows.
    private var compared = (offsetHours: 0, toleranceSeconds: 3)
    /// The comparison was stopped: its rows are right but not all of them.
    internal private(set) var isPartial = false
    /// The left directory, the source of a mirror, listed as empty while the right one is not: an unmounted
    /// share or a wrong path looks like this, and mirroring it would delete the whole right side.
    internal private(set) var sourceLooksEmpty = false
    /// The summary line of the rows, and the layout of the list, made by `layout` (off the main thread for large lists).
    private var summary = SyncSummary([])
    private var layoutGeneration = 0
    private var actionEpoch = 0
    /// The same for this session (tests make it small).
    internal var worksInBackgroundFrom = SyncSession.backgroundFrom
    /// The least time between two progress reports of a comparison, in seconds (tests: none).
    internal var progressInterval: TimeInterval = 0.1
    /// Starts the work of a comparison, a list or a plan away from the main thread (tests keep
    /// it, to run it when they choose).
    internal var startWorker: (_ name: String, _ work: @escaping @Sendable () -> Void) -> Void = {
        SyncWorker.run($0, $1)
    }
    private var isPlanning = false
    /// Counts the calls of `adopt`: a long selection read in the background is dropped when another began.
    private var selectionEpoch = 0

    private var fileSystems: FileSystemRegistry { kernel.fileSystems }

    // MARK: The list

    internal var visibleRows: [Int] {
        entries.compactMap { entry in
            if case .row(let index) = entry {
                return index
            }
            return nil
        }
    }

    /// The time tolerance the run uses: the one the comparison found necessary.
    private var runTolerance: Int { compared.toleranceSeconds }

    internal var canSynchronize: Bool { phase == .compared && actionableCount > 0 && !isPartial && !isPlanning }

    private var currentLayout: Layout {
        Layout(
            entries: entries,
            positions: positions,
            headerPositions: headerPositions,
            actionableCount: actionableCount,
            summary: summary
        )
    }

    /// The saved sets, sorted by name (spec 09 › Saved sync sets).
    ///
    /// A set that cannot be read is left out; the others stay.
    internal var savedSets: [SyncSet] {
        (settings.value([StoredElement<SyncSet>].self, forKey: SyncSettingsKey.sets) ?? []).compactMap(\.value)
            .sorted { Sorter.compare($0.name, $1.name, numeric: true) == .orderedAscending }
    }

    internal init(kernel: Kernel) {
        self.kernel = kernel
        settings = kernel.settings.scoped(to: SyncSettingsKey.scope)
        options = settings.value(SyncOptions.self, forKey: SyncSettingsKey.options) ?? SyncOptions()
        var show = settings.value(SyncShow.self, forKey: SyncSettingsKey.show) ?? .all
        // With both up nothing would ever be shown (spec 09 › Show filter).
        if !show.contains(.duplicates), !show.contains(.singles) { show.formUnion([.duplicates, .singles]) }
        self.show = show
    }

    /// The sorted names of the marked entries of the panels the snapshots were taken of.
    nonisolated internal static func names(of snapshots: [PanelModel.Operands]) -> [String] {
        snapshots.flatMap { $0.markedItems().map(\.name) }.sorted()
    }
    nonisolated private static func isActionable(_ row: SyncRow) -> Bool {
        row.action != .none && row.accepts(row.action)
    }

    /// Filters by the Show buttons, sorts inside each subdirectory and puts the captions in.
    nonisolated internal static func layout(
        rows: [SyncRow],
        show: SyncShow,
        sort: (key: SyncSortKey, side: SyncSide, ascending: Bool)
    )
        -> Layout
    {
        // The comparison delivers the rows grouped by folder, so a row mostly belongs to the group of the one before.
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
        var layout = Layout()
        layout.entries.reserveCapacity(rows.count + groups.count)
        for (group, directory) in order.enumerated() {
            if !directory.isEmpty { layout.entries.append(.header(directory)) }
            layout.entries += sorted(groups[group], rows: rows, by: sort).map(SyncListEntry.row)
        }
        layout.positions = [Int](repeating: -1, count: rows.count)
        for (position, entry) in layout.entries.enumerated() {
            switch entry {
            case .header:
                layout.headerPositions.append(position)

            case .row(let index):
                layout.positions[index] = position
                if isActionable(rows[index]) { layout.actionableCount += 1 }
            }
        }
        layout.summary = SyncSummary(rows)
        return layout
    }

    /// Orders the rows of one folder.
    ///
    /// The keys (a size, a date) are taken out once, and the pairs of key and row are sorted:
    /// sorting the rows by looking into their files on every comparison takes seconds at a million.
    nonisolated private static func sorted(
        _ indexes: [Int],
        rows: [SyncRow],
        by sort: (key: SyncSortKey, side: SyncSide, ascending: Bool)
    ) -> [Int] {
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
        let ordered = indexes.map { (key: key($0), index: $0) }.sorted { ($0.key, $0.index) < ($1.key, $1.index) }
            .map(
                \.index
            )
        return sort.ascending ? ordered : ordered.reversed()
    }

    /// Presets the window with the directories and the selection of the two panels.
    internal func adopt(
        left: PanelModel,
        right: PanelModel,
        includeHidden: Bool,
        readsInBackgroundFrom: Int = SyncSession.backgroundFrom
    ) {
        // While the files are being synchronized the window keeps showing that: the paths, rows and
        // phase are those of the run, and a second plan must not start under it.
        guard phase != .synchronizing else {
            return
        }
        base = left.directory
        leftPath = kernel.fileSystems.displayPath(left.directory)
        rightPath = kernel.fileSystems.displayPath(right.directory)
        // By the entries, not the set of names: of two names that differ in normalisation only, each counts.
        // Nothing marked costs nothing; a short selection is read here, a long one (the marks of a
        // list of a million) in the background, and the window learns of it when it is known.
        selectionEpoch += 1
        let epoch = selectionEpoch
        let marked = [left, right].filter { $0.selectionCount > 0 }
        if marked.isEmpty {
            selectedNames = []
        } else if marked.reduce(0, { $0 + $1.selectionCount }) < readsInBackgroundFrom {
            selectedNames = Self.names(of: marked.map { $0.operandsSnapshot() })
        } else {
            selectedNames = []
            let snapshots = marked.map { $0.operandsSnapshot() }
            DispatchQueue.global(qos: .userInitiated)
                .async { [weak self] in
                    let names = Self.names(of: snapshots)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.selectionEpoch == epoch else {
                            return
                        }
                        self.selectedNames = names
                        self.changed()
                    }
                }
        }
        onlySelected = false
        options.includeHidden = includeHidden
        options.onlyNames = nil
        picked = (nil, nil)
        clear()
    }

    internal func location(_ side: SyncSide) -> URL {
        fileSystems.location(from: side == .left ? leftPath : rightPath, relativeTo: base)
    }

    private func changed() {
        onChange()
    }

    private func clear() {
        // A comparison still running is of the old paths: it is stopped, and its rows are not taken.
        running?.cancellation.cancel()
        running = nil
        rows = []
        phase = .idle
        isPartial = false
        sourceLooksEmpty = false
        status = "Please press 'Compare' to start"
        fraction = nil
        rebuild(rowsChanged: true)
    }

    // MARK: Comparing

    internal func compare() {
        guard phase != .comparing, phase != .synchronizing, !isPlanning else {
            return
        }
        var options = self.options
        options.onlyNames = onlySelected && !selectedNames.isEmpty ? selectedNames : nil
        rememberOptions()
        let (left, right) = (location(.left), location(.right))
        let comparison = SyncComparison(options: options, fileSystems: fileSystems)
        running = comparison
        rows = []
        phase = .comparing
        isPartial = false
        sourceLooksEmpty = false
        status = "Comparing…"
        fraction = nil
        rebuild(rowsChanged: true)

        if runsInline {
            finish(comparison, comparison.run(left: left, right: right), left, right)
            return
        }
        // A thread of its own: listing a share that does not answer can block for as long as the server
        // takes to give up, and a few such comparisons must not use up the workers of the shared pool.
        let interval = progressInterval
        startWorker("Synchronize directories: compare") { [weak self] in
            // What comes back for a comparison that was stopped or replaced meanwhile is dropped.
            let whileCurrent: @Sendable (@escaping @MainActor @Sendable (SyncSession) -> Void) -> Void = {
                [weak self] work in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.running === comparison else {
                        return
                    }
                    work(self)
                }
            }
            /// Belongs to the comparison's progress calls, which arrive one at a time.
            nonisolated(unsafe) var lastReport = Date.distantPast
            let result = comparison.run(left: left, right: right) { progress in
                guard Date().timeIntervalSince(lastReport) >= interval else {
                    return
                }
                lastReport = Date()
                whileCurrent { $0.show(progress) }
            }
            whileCurrent { $0.finish(comparison, result, left, right) }
        }
    }

    /// Stops a running comparison; what was found so far is shown.
    internal func cancelComparison() {
        running?.cancellation.cancel()
    }

    private func show(_ progress: SyncProgress) {
        if progress.filesToCompare > 0 {
            fraction =
                progress.bytesToCompare > 0 ? Double(progress.bytesCompared) / Double(progress.bytesToCompare) : nil
            status =
                "Comparing by content: \(progress.filesCompared) / \(progress.filesToCompare) files, "
                + "\(Format.bytes(progress.bytesCompared)) / \(Format.bytes(progress.bytesToCompare)) bytes"
                + (fraction.map { " (\(Int($0 * 100)) %)" } ?? "")
        } else {
            status =
                "Comparing: \(progress.leftDirectories) directories on the left, \(progress.rightDirectories) on the right"
        }
        changed()
    }

    private func finish(_ comparison: SyncComparison, _ result: SyncResult, _ left: URL, _ right: URL) {
        running = nil
        rows = result.rows
        roots = (left, right)
        compared = (comparison.options.timeOffsetHours, result.toleranceSeconds)
        phase = .compared
        fraction = nil
        isPartial = result.wasCancelled
        // A mirror (asymmetric) of a source that is empty or gone would delete the whole target.
        sourceLooksEmpty =
            comparison.options.asymmetric && result.topEntries.left == 0 && (result.topEntries.right ?? 0) > 0
        rebuild(rowsChanged: true)
        if sourceLooksEmpty {
            kernel.interaction.inform(
                "The left directory is empty.",
                detail:
                    "\(fileSystems.displayPath(left)) holds nothing, but \(fileSystems.displayPath(right)) does. Synchronizing would "
                    + "delete everything on the right. If the left directory is a network share or a drive, it may not be mounted. "
                    + "The deletion is not ticked in the Synchronize dialog; tick it only if this is what you want.",
                style: .warning
            )
        }
        if !result.errors.isEmpty, settings.flag(SyncSettingsKey.warnReadErrors, default: true) {
            let shown =
                result.errors.prefix(12).joined(separator: "\n")
                + (result.errors.count > 12 ? "\n… and \(result.errors.count - 12) more" : "")
            kernel.interaction.inform(
                "Some directories or files could not be read. They are left out of the comparison.",
                detail: shown,
                style: .warning
            )
        }
    }

    private func isActionable(_ row: SyncRow) -> Bool { Self.isActionable(row) }

    /// Lays the list out again.
    ///
    /// The rows of a large list are worked on away from the main thread, and the previous list
    /// stays on show until the new one has come; where the rows themselves are new (`rowsChanged`)
    /// there is nothing to show meanwhile.
    private func rebuild(rowsChanged: Bool) {
        layoutGeneration += 1
        let generation = layoutGeneration
        if rowsChanged {
            entries = []
            positions = []
            headerPositions = []
            actionableCount = 0
        }
        if runsInline || rows.count < worksInBackgroundFrom {
            apply(Self.layout(rows: rows, show: show, sort: sort))
            return
        }
        let (rows, show, sort, epoch) = (self.rows, self.show, self.sort, actionEpoch)
        if phase == .compared { status = "Preparing the list of \(rows.count) files…" }
        changed()
        startWorker("Synchronize directories: list") { [weak self] in
            let layout = Self.layout(rows: rows, show: show, sort: sort)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else {
                    return
                }
                // Actions set while the list was made are counted again.
                self.apply(layout, recount: self.actionEpoch != epoch)
            }
        }
    }

    private func apply(_ layout: Layout, recount: Bool = false) {
        entries = layout.entries
        positions = layout.positions
        headerPositions = layout.headerPositions
        actionableCount = layout.actionableCount
        summary = layout.summary
        if recount {
            actionableCount = entries.reduce(0) { count, entry in
                if case .row(let index) = entry, rows.indices.contains(index), isActionable(rows[index]) {
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
            if headerPositions[middle] <= position { low = middle + 1 } else { high = middle }
        }
        let current = low > 0 ? low - 1 : nil
        var name = ""
        if let current, case .header(let text) = entries[headerPositions[current]] { name = text }
        return "\(current.map { $0 + 1 } ?? 0)/\(headerPositions.count) \(name)"
    }

    /// The entry of the next or previous subdirectory caption, for Ctrl+PgDn / Ctrl+PgUp.
    internal func header(after position: Int, forward: Bool) -> Int? {
        forward ? headerPositions.first { $0 > position } : headerPositions.last { $0 < position }
    }

    // MARK: Actions of rows

    /// Sets the action of every given row that can take it.
    internal func setAction(_ action: SyncAction, rows indexes: [Int]) {
        change(indexes) { $0.accepts(action) ? action : $0.action }
    }

    /// "Mark for copying (default direction)".
    internal func markDefault(rows indexes: [Int]) {
        change(indexes) { $0.defaultAction }
    }

    internal func reverse(rows indexes: [Int]) {
        change(indexes) { $0.reversedAction }
    }

    /// Space: switches each row between its default action and none.
    internal func toggle(rows indexes: [Int]) {
        change(indexes) { $0.action == .none ? $0.defaultAction : .none }
    }

    /// A click on the middle column.
    internal func cycle(row index: Int) {
        change([index]) { $0.nextAction }
    }

    private func change(_ indexes: [Int], _ action: (SyncRow) -> SyncAction) {
        // While the plan is made nothing may change under it.
        guard !isPlanning else {
            return
        }
        var touched: [Int] = []
        for index in indexes where rows.indices.contains(index) {
            let new = action(rows[index])
            guard new != rows[index].action else { continue }
            let wasActionable = isActionable(rows[index])
            rows[index].action = new
            actionEpoch += 1
            if positions.indices.contains(index), positions[index] >= 0 {
                actionableCount += (isActionable(rows[index]) ? 1 : 0) - (wasActionable ? 1 : 0)
            }
            touched.append(index)
        }
        if let onRowsChange { onRowsChange(touched) } else { changed() }
    }

    // MARK: Files of rows

    internal func url(_ side: SyncSide, row index: Int) -> URL? {
        guard rows.indices.contains(index), !rows[index].isDirectory else {
            return nil
        }
        return side == .left ? rows[index].left?.url : rows[index].right?.url
    }

    internal func view(_ side: SyncSide, row index: Int, command: CommandID = .view) {
        guard let url = url(side, row: index) else {
            return
        }
        kernel.commands.perform(command, .location(url))
    }

    /// "Select for comparison": remembers a file of one side for "Compare left & right".
    internal func pick(_ side: SyncSide, row index: Int) {
        guard let url = url(side, row: index) else {
            return
        }
        if side == .left { picked.left = url } else { picked.right = url }
        changed()
    }

    /// "Compare left & right": the two picked files when one was picked on each side, else
    /// the two files of the row.
    ///
    /// The comparison tool is another plugin's command; it is handed the two locations as two lines
    /// of text.
    internal func compareContents(row index: Int?) {
        var files = (left: picked.left, right: picked.right)
        if files.left == nil || files.right == nil {
            guard let index else {
                return
            }
            files = (url(.left, row: index), url(.right, row: index))
        }
        guard files.left != nil || files.right != nil else {
            return
        }
        guard kernel.commands[.compareByContent] != nil else {
            kernel.interaction.inform("Compare by content is not available.")
            return
        }
        picked = (nil, nil)
        kernel.commands.perform(
            .compareByContent,
            .text((files.left?.absoluteString ?? "") + "\n" + (files.right?.absoluteString ?? ""))
        )
        changed()
    }

    // MARK: Synchronizing

    /// What Synchronize would do now: only the rows that are shown take part.
    internal func plan() -> SyncPlan {
        SyncPlan(rows: visibleRows.map { rows[$0] }, timeOffsetHours: compared.offsetHours)
    }

    /// Shows the Synchronize dialog and runs what the user confirmed
    /// (spec 09 › The "Synchronize" dialog and the run).
    internal func synchronize() {
        guard phase == .compared, !isPlanning else {
            return
        }
        if runsInline || rows.count < worksInBackgroundFrom {
            present(plan())
            return
        }
        // Planning copies every shown row; with a million rows that is not for the main thread. Nothing is
        // changed in the list meanwhile (`isPlanning`).
        isPlanning = true
        let (rows, entries, offset) = (self.rows, self.entries, compared.offsetHours)
        status = "Preparing the plan…"
        changed()
        startWorker("Synchronize directories: plan") { [weak self] in
            var visible: [SyncRow] = []
            visible.reserveCapacity(entries.count)
            for case .row(let index) in entries where rows.indices.contains(index) { visible.append(rows[index]) }
            let plan = SyncPlan(rows: visible, timeOffsetHours: offset)
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isPlanning = false
                self.apply(self.currentLayout)
                guard self.phase == .compared else {
                    return
                }
                self.present(plan)
            }
        }
    }

    /// Asks about the plan of the last comparison and runs it.
    ///
    /// Only while the comparison's rows are shown (`phase` is `.compared`).
    private func present(_ plan: SyncPlan) {
        var plan = plan
        guard !plan.isEmpty else {
            return
        }
        let asymmetric = options.asymmetric
        let hasDeletions = !plan.deleteLeft.isEmpty || !plan.deleteRight.isEmpty || asymmetric
        let (leftText, rightText) = (fileSystems.displayPath(roots.left), fileSystems.displayPath(roots.right))

        var fields: [FormField] = []
        if !plan.toRight.isEmpty {
            fields += [
                .checkbox("toRight", "Left to right: " + SyncPlan.describe(plan.toRight), true),
                .text("rightTarget", "Target:", rightText)
            ]
        }
        if !plan.toLeft.isEmpty {
            fields += [
                .checkbox("toLeft", "Right to left: " + SyncPlan.describe(plan.toLeft), true),
                .text("leftTarget", "Target:", leftText)
            ]
        }
        // Deletions say where they are done. Against a source that looks empty they are not ticked: they
        // happen only if the user asks for them here.
        let deletionsTicked = !sourceLooksEmpty
        if sourceLooksEmpty, !plan.deleteRight.isEmpty {
            fields.append(
                .note(
                    "The left directory is empty or not available. Tick the deletion only if everything on the right is to go."
                )
            )
        }
        if !plan.deleteRight.isEmpty {
            fields.append(
                .checkbox(
                    "deleteRight",
                    "Right: Delete \(plan.deleteRight.count) file(s) in \(rightText)",
                    deletionsTicked
                )
            )
        }
        if !plan.deleteLeft.isEmpty {
            fields.append(
                .checkbox("deleteLeft", "Left: Delete \(plan.deleteLeft.count) file(s) in \(leftText)", true)
            )
        }
        if asymmetric {
            fields.append(.checkbox("emptyDirectories", "Right: Delete all empty directories in \(rightText)", false))
        }
        fields.append(
            .checkbox(
                "confirm",
                "Confirm overwrites",
                settings.flag(SyncSettingsKey.confirmOverwrites, default: true)
            )
        )
        if hasDeletions {
            fields.append(
                .checkbox(
                    "direct",
                    "Delete directly instead of moving to the Trash",
                    !settings.flag(SyncSettingsKey.useTrash, default: true)
                )
            )
        }
        guard let answer = kernel.interaction.form("Synchronize", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }

        var run = SyncRunOptions()
        run.copyToRight = answer.flag("toRight")
        run.copyToLeft = answer.flag("toLeft")
        run.deleteRight = answer.flag("deleteRight")
        run.deleteLeft = answer.flag("deleteLeft")
        run.confirmOverwrites = answer.flag("confirm")
        run.useTrash = !answer.flag("direct")
        run.removeEmptyDirectoriesBelow = answer.flag("emptyDirectories") ? roots.right : nil
        run.mayChangeSourceDates =
            !options.ignoreDate && settings.flag(SyncSettingsKey.changeSourceDates, default: true)
        run.toleranceSeconds = runTolerance
        // Another target folder may be named for each direction.
        for (toRight, key, original) in [(true, "rightTarget", rightText), (false, "leftTarget", leftText)] {
            let text = answer.text(key).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text != original {
                kernel.userTyped(location: text, relativeTo: base)
                plan.retarget(toRight: toRight, root: fileSystems.location(from: text, relativeTo: base))
            }
        }

        let (ui, fileSystems) = (kernel.interaction, self.fileSystems)
        // The progress window is another window: until the job is over neither Synchronize nor Compare may start.
        phase = .synchronizing
        changed()
        kernel.jobs.run(
            title: "Synchronize",
            work: { [plan, run] monitor -> SyncOutcome in
                let executor = SyncExecutor(
                    plan: plan,
                    options: run,
                    fileSystems: fileSystems,
                    cancellation: monitor.cancellation
                )
                executor.onProgress = monitor.report
                executor.onOverwrite = { target, copy in
                    monitor.ask { @MainActor @Sendable in
                        ui.pick(
                            "Overwrite \(fileSystems.displayPath(target.url))?",
                            detail:
                                "\(Format.bytes(target.size)) bytes, \(Format.date(target.modified))\n\nwith \(fileSystems.displayPath(copy.source))\n"
                                + "\(Format.bytes(copy.size)) bytes, \(Format.date(copy.modified))",
                            [
                                ("Overwrite", SyncOverwriteAnswer.overwrite), ("Overwrite All", .overwriteAll),
                                ("Skip", .skip),
                                ("Skip All", .skipAll), ("Cancel", .cancel)
                            ],
                            fallback: .cancel
                        )
                    }
                }
                executor.onError = { url, error in
                    monitor.ask { @MainActor @Sendable in
                        ui.pick(
                            "Error with \(fileSystems.displayPath(url))",
                            detail: error.localizedDescription,
                            [
                                ("Skip", SyncErrorAnswer.skip), ("Skip All", .skipAll), ("Retry", .retry),
                                ("Cancel", .cancel)
                            ],
                            fallback: .cancel
                        )
                    }
                }
                return executor.run()
            },
            completion: { [weak self] outcome in
                self?.finished(outcome)
            }
        )
    }

    private func finished(_ outcome: SyncOutcome) {
        phase = .compared
        kernel.panels.refresh(outcome.changedDirectories)
        report(outcome)
        // The comparison runs again by itself, so the list shows what is left to do
        // (`SyncRecompareAfterCopy`).
        if settings.flag(SyncSettingsKey.recompare, default: true) {
            compare()
        } else {
            clear()
        }
    }

    /// Says what did not go well: failures (also those after "Skip All", which asked no more), a
    /// write that could not be made durable (the deletions were then not done), a run that was stopped.
    internal func report(_ outcome: SyncOutcome) {
        guard !outcome.errors.isEmpty || outcome.commitFailed || outcome.wasCancelled else {
            return
        }
        var lines = ["Copied: \(outcome.copied), deleted: \(outcome.deleted), left alone: \(outcome.skipped)."]
        if outcome.commitFailed {
            lines.append("What was written could not be made permanent, so nothing was deleted.")
        }
        if outcome.wasCancelled { lines.append("The run was stopped before it was finished.") }
        if !outcome.errors.isEmpty {
            lines.append("")
            lines += outcome.errors.prefix(12)
            if outcome.errors.count > 12 { lines.append("… and \(outcome.errors.count - 12) more") }
        }
        kernel.interaction.inform(
            outcome.errors.isEmpty && !outcome.commitFailed
                ? "Synchronize was stopped." : "Synchronize did not finish without errors.",
            detail: lines.joined(separator: "\n"),
            style: .warning
        )
    }

    // MARK: Remembered options and saved sets

    private func rememberOptions() {
        var remembered = options
        remembered.onlyNames = nil
        settings.set(remembered, forKey: SyncSettingsKey.options)
        settings.set(show, forKey: SyncSettingsKey.show)
    }

    /// "Add current directories and settings to list"; a set of the same name is replaced.
    internal func saveSet(named name: String) {
        var saved = options
        saved.onlyNames = nil
        let set = SyncSet(name: name, left: leftPath, right: rightPath, options: saved, show: show)
        settings.set(savedSets.filter { $0.name != name } + [set], forKey: SyncSettingsKey.sets)
    }

    internal func removeSet(named name: String) {
        settings.set(savedSets.filter { $0.name != name }, forKey: SyncSettingsKey.sets)
    }

    @discardableResult
    internal func loadSet(named name: String) -> Bool {
        guard phase != .synchronizing, let set = savedSets.first(where: { $0.name == name }) else {
            return false
        }
        let includeHidden = options.includeHidden
        leftPath = set.left
        rightPath = set.right
        options = set.options
        options.includeHidden = includeHidden
        onlySelected = false
        clear()
        show = set.show
        return true
    }
}

/// Where the session's comparison, list and plan are made: a thread of their own for each, not a worker
/// of the shared pool (see `SyncSession.compare`).
internal enum SyncWorker {
    internal static func run(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
    }
}
