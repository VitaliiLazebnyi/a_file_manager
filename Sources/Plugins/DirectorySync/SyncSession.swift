import AFMContracts
import AFMKernel
import Foundation

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
    /// Work on the session that comes back to the main thread from a comparison in the background.
    private typealias Delivery = @MainActor @Sendable (SyncSession) -> Void

    /// What the session is doing.
    internal enum Phase {
        /// The rows of the last comparison are shown and can be synchronized.
        case compared
        /// A comparison runs.
        case comparing
        /// Nothing is compared: at the start, and after the paths or options changed.
        case idle
        /// The job that carries out the plan runs; neither Compare nor Synchronize may start.
        case synchronizing
    }

    /// Rows from this many on are laid out and planned away from the main thread.
    internal static let backgroundFrom = 20_000

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The settings of Synchronize directories (below `directorySync.`).
    internal let settings: any SettingsStore

    /// The left directory as the user sees and types it.
    internal var leftPath = ""
    /// The right directory as the user sees and types it.
    internal var rightPath = ""
    /// The compare options of the window.
    internal var options: SyncOptions
    /// The Show buttons.
    internal var show: SyncShow { didSet { rebuild(rowsChanged: false) } }
    /// How the rows of each folder are ordered.
    internal var sort = SyncSort(key: .name, side: .left, ascending: true) {
        didSet { rebuild(rowsChanged: false) }
    }
    /// "Only selected (in main window)".
    internal var onlySelected = false
    /// The names that were selected in the two panels when the window was opened.
    internal private(set) var selectedNames: [String] = []
    /// Whether the comparison runs on the calling thread instead (tests).
    internal var runsInline = false
    /// Called on the main thread whenever something the window shows has changed.
    internal var onChange: () -> Void = {
        // Nobody listens until the window does.
    }
    /// Called instead of `onChange` when only the actions of these rows (indexes into `rows`)
    /// changed, so that the window redraws just them.
    internal var onRowsChange: (([Int]) -> Void)?

    /// The rows of the last comparison, with the actions the user chose.
    internal var rows: [SyncRow] = []
    /// The list as it is shown.
    internal var entries: [SyncListEntry] = []
    /// The position in `entries` of each row, -1 for a row that is not shown.
    internal var positions: [Int] = []
    /// The positions of the captions in `entries`, in order.
    internal var headerPositions: [Int] = []
    /// How many of the shown rows have an action that the plan would carry out.
    internal var actionableCount = 0
    /// What the session is doing.
    internal var phase = Phase.idle
    /// The status line: what was found, or what is going on.
    internal var status = "Please press 'Compare' to start"
    /// 0…1 while files are compared by content.
    internal private(set) var fraction: Double?
    /// The files picked with "Select for comparison", one per side.
    internal var picked: (left: URL?, right: URL?) = (nil, nil)

    /// The folder typed paths are relative to: the left panel's.
    internal private(set) var base = URL(fileURLWithPath: "/")
    /// The two directories of the last finished comparison; what they are counts only once it
    /// has finished (`phase` is `.compared` or `.synchronizing`).
    internal private(set) var roots = (left: URL(fileURLWithPath: "/"), right: URL(fileURLWithPath: "/"))
    /// The comparison that runs; nil when none does.
    private var running: SyncComparison?
    /// What the last finished comparison used and found, for what is done with its rows.
    internal private(set) var compared = (offsetHours: 0, toleranceSeconds: 3)
    /// The comparison was stopped: its rows are right but not all of them.
    internal private(set) var isPartial = false
    /// The left directory, the source of a mirror, listed as empty while the right one is not: an unmounted
    /// share or a wrong path looks like this, and mirroring it would delete the whole right side.
    internal private(set) var sourceLooksEmpty = false
    /// The summary line of the rows, and the layout of the list, made by `layout` (off the main thread for
    /// large lists).
    internal var summary = SyncSummary([])
    /// Counts the layouts asked for: a layout made in the background is dropped when a newer one was asked for.
    internal var layoutGeneration = 0
    /// Counts the changes of actions, so that a layout made meanwhile counts its actions again.
    internal var actionEpoch = 0
    /// The same for this session (tests make it small).
    internal var worksInBackgroundFrom = SyncSession.backgroundFrom
    /// The least time between two progress reports of a comparison, in seconds (tests: none).
    internal var progressInterval: TimeInterval = 0.1
    /// Starts the work of a comparison, a list or a plan away from the main thread (tests keep
    /// it, to run it when they choose).
    internal var startWorker: (_ name: String, _ work: @escaping @Sendable () -> Void) -> Void = { name, work in
        SyncWorker.run(name, work)
    }
    /// Whether the plan is being made in the background; nothing in the list may change meanwhile.
    internal var isPlanning = false
    /// Counts the calls of `adopt`: a long selection read in the background is dropped when another began.
    private var selectionEpoch = 0

    /// The kernel's file systems, through which both sides are read.
    internal var fileSystems: FileSystemRegistry { kernel.fileSystems }

    /// A session with the options and the Show buttons last used.
    internal init(kernel: Kernel) {
        self.kernel = kernel
        settings = kernel.settings.scoped(to: SyncSettingsKey.scope)
        options = settings.value(SyncOptions.self, forKey: SyncSettingsKey.options) ?? SyncOptions()
        var shown = settings.value(SyncShow.self, forKey: SyncSettingsKey.show) ?? .all
        // With both up nothing would ever be shown (spec 09 › Show filter).
        if !shown.contains(.duplicates), !shown.contains(.singles) {
            shown.formUnion([.duplicates, .singles])
        }
        self.show = shown
    }

    /// The sorted names of the marked entries of the panels the snapshots were taken of.
    nonisolated internal static func names(of snapshots: [PanelModel.Operands]) -> [String] {
        snapshots.flatMap { snapshot in snapshot.markedItems().map(\.name) }.sorted()
    }

    /// Presets the window with the directories and the selection of the two panels.
    ///
    /// A selection of `readsInBackgroundFrom` names or more is read away from the main thread.
    internal func adopt(left: PanelModel, right: PanelModel, includeHidden: Bool, readsInBackgroundFrom: Int) {
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
        let marked = [left, right].filter { model in model.selectionCount > 0 }
        if marked.isEmpty {
            selectedNames = []
        } else if marked.reduce(0, { count, model in count + model.selectionCount }) < readsInBackgroundFrom {
            selectedNames = Self.names(of: marked.map { model in model.operandsSnapshot() })
        } else {
            selectedNames = []
            let snapshots = marked.map { model in model.operandsSnapshot() }
            DispatchQueue.global(qos: .userInitiated)
                .async { [weak self] in
                    let names = Self.names(of: snapshots)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, selectionEpoch == epoch else {
                            return
                        }
                        selectedNames = names
                        changed()
                    }
                }
        }
        onlySelected = false
        options.includeHidden = includeHidden
        options.onlyNames = []
        picked = (nil, nil)
        clear()
    }

    /// The directory a side's path names, relative to `base`.
    internal func location(_ side: SyncSide) -> URL {
        fileSystems.location(from: side == .left ? leftPath : rightPath, relativeTo: base)
    }

    /// Tells the window that something it shows has changed.
    internal func changed() {
        onChange()
    }

    /// Forgets the rows: a comparison still running is stopped, and the list is empty.
    internal func clear() {
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

    /// Compares the two directories, in the background unless `runsInline`; the rows come when it is done.
    internal func compare() {
        guard phase != .comparing, phase != .synchronizing, !isPlanning else {
            return
        }
        var asked = options
        asked.onlyNames = onlySelected ? selectedNames : []
        rememberOptions()
        let (left, right) = (location(.left), location(.right))
        let comparison = SyncComparison(options: asked, fileSystems: fileSystems)
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
            let whileCurrent: @Sendable (@escaping Delivery) -> Void = { [weak self] work in
                DispatchQueue.main.async { [weak self] in
                    guard let self, running === comparison else {
                        return
                    }
                    work(self)
                }
            }
            // Belongs to the comparison's progress calls, which arrive one at a time.
            nonisolated(unsafe) var lastReport = Date.distantPast
            let result = comparison.run(left: left, right: right) { progress in
                guard Date().timeIntervalSince(lastReport) >= interval else {
                    return
                }
                lastReport = Date()
                whileCurrent { session in session.show(progress) }
            }
            whileCurrent { session in session.finish(comparison, result, left, right) }
        }
    }

    /// Stops a running comparison; what was found so far is shown.
    internal func cancelComparison() {
        running?.cancellation.cancel()
    }

    /// Shows how far the comparison is in the status line.
    private func show(_ progress: SyncProgress) {
        if progress.filesToCompare > 0 {
            fraction =
                progress.bytesToCompare > 0 ? Double(progress.bytesCompared) / Double(progress.bytesToCompare) : nil
            status =
                "Comparing by content: \(progress.filesCompared) / \(progress.filesToCompare) files, "
                + "\(Format.bytes(progress.bytesCompared)) / \(Format.bytes(progress.bytesToCompare)) bytes"
                + (fraction.map { done in " (\(Int(done * 100)) %)" } ?? "")
        } else {
            status =
                "Comparing: \(progress.leftDirectories) directories on the left, "
                + "\(progress.rightDirectories) on the right"
        }
        changed()
    }

    /// Takes the rows of a finished comparison, and warns of an empty source and of what could not be read.
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
                    "\(fileSystems.displayPath(left)) holds nothing, but \(fileSystems.displayPath(right)) does. "
                    + "Synchronizing would delete everything on the right. If the left directory is a network share "
                    + "or a drive, it may not be mounted. The deletion is not ticked in the Synchronize dialog; tick "
                    + "it only if this is what you want.",
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

    deinit {
        // Nothing to release.
    }
}
