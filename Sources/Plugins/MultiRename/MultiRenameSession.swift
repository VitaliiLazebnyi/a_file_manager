import AFMKernel
import Foundation

/// The state of the Multi-Rename Tool without its window (spec 09 › Multi-Rename Tool): the
/// list of items, the settings, the live preview, and Start!, Undo and the result list.
///
/// **Threading.** A session belongs to the main thread. Previews are computed on a background
/// queue (the names on all cores) and handed back to the main thread; one that was overtaken
/// by a newer change is dropped, also while it is under way (even a regular expression in the
/// middle of a name stops). A change of the fields starts its preview after a short pause, so
/// that typing does not start one per key. Renaming runs as a job on the job's thread and works
/// on a copy of the list taken when it starts; while a run or an Undo is under way the list
/// cannot be changed. What the main thread keeps is O(1) per change of the fields: the entries
/// are kept in an array of their own, the preview hands back the counts, and the clipboard is
/// read, in the background, only when a mask uses it.
@MainActor
internal final class MultiRenameSession {
    /// One row of the list as it shows it.
    internal struct Row {
        /// The item and the name the masks work on.
        internal var entry: RenameEntry
        /// Nil is `<Error!>`.
        internal var newName: String?
        /// How the item stands.
        internal var status: RenameStatus
    }

    /// A column the list can be sorted by.
    internal enum SortKey {
        /// The modification date.
        case date
        /// The extension, then the name.
        case ext
        /// The name.
        case name
        /// The size.
        case size
    }

    /// The pause between the last change of a field and the preview it starts.
    internal static let typingPause: TimeInterval = 0.1

    /// Lists at least this long are worked on off the main thread.
    internal static let backgroundSortThreshold = 2_000

    /// The saved settings, the histories and the runs that can be undone.
    internal let store: RenameStore
    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// Whether previews, sorts and the reading of name lists run in the background (with a window) or at
    /// once (in tests without one).
    internal let previewsInBackground: Bool
    /// The queue of the long sorts and of "next step": a long one does not hold the previews up.
    internal let sortQueue = DispatchQueue(label: "multirename.sort", qos: .userInitiated)
    /// The entries of the list, their new names and how they stand: parallel arrays, so that a
    /// preview is taken in by assigning two of them.
    internal var entries: [RenameEntry]
    /// The new name of each entry, as the last preview made it.
    internal var newNames: [String?]
    /// How each entry stands, as the last preview found.
    internal var statuses: [RenameStatus]
    /// Names loaded from a file or typed by the user, in list order; they take the place of the masks.
    ///
    /// Empty: the masks make the names.
    internal var givenNames: [String] = []
    /// What the previews of the current list share; replaced when the list changes.
    internal var cache = RenameCache()
    /// Counts the changes of the list, so that a sort that finishes late can see it was overtaken.
    internal var listGeneration = 0
    /// Counts the sorts asked for: of two sorts under way, the last one is the one that counts.
    internal var sortRequest = 0
    /// The rule of title case; read again when a run starts.
    internal var titleRule: TitleCaseRule
    /// What is wrong with the masks or the expression, if anything.
    internal private(set) var problem: (any Error)?
    /// A preview, a long sort or a "next step" is under way.
    internal var isComputing = false
    /// A run or an Undo is under way: the list stays as it is until it is over.
    internal var isBusy = false
    /// The renames of the last run of this session, for the result list.
    internal var lastRun: [RenamedItem] = []
    /// How the items stand; worked out with the preview.
    internal private(set) var counts = RenamePreview.Counts()
    /// Called on the main thread whenever rows, preview or buttons may look different.
    internal var onChange: (() -> Void)?
    private let logDirectory: URL
    private let clipboard: ClipboardSource
    private let environment = ProcessInfo.processInfo.environment
    private let opened = Date()
    private var optionsChanged = Date()
    private let queue = DispatchQueue(label: "multirename.preview", qos: .userInitiated)
    /// Stops the preview that is under way when a newer one starts.
    private var previewCancellation = CancellationFlag()
    /// Counts the changes of the fields, so that a preview waiting out the pause can see it was overtaken.
    private var refreshRequest = 0

    /// What the fields hold; a change starts a preview.
    internal var settings: RenameSettings {
        didSet {
            guard settings != oldValue else {
                return
            }
            optionsChanged = Date()
            scheduleRefresh()
        }
    }

    /// The rows as the list shows them.
    ///
    /// Made on each call: ask for one row with `row(at:)`.
    internal var rows: [Row] { entries.indices.map(row(at:)) }
    /// The number of rows.
    internal var rowCount: Int { entries.count }

    /// The new names as they stand, the old one where there is none.
    internal var targetNames: [String] { entries.indices.map { newNames[$0] ?? entries[$0].name } }

    /// Where the result log of a run is written.
    internal var logURL: URL { logDirectory.appendingPathComponent(RenameLog.fileName) }
    /// Whether Undo can be pressed: a run of an earlier session or this one can be undone, and nothing runs.
    internal var canUndo: Bool { !isBusy && store.undoLimit > 0 && store.undoCount > 0 }
    /// Whether the result list of the last run can be shown.
    internal var hasResultList: Bool { !lastRun.isEmpty }

    /// A session for `items`, with `settings` in the fields; previews in the background when
    /// `previewsInBackground`.
    ///
    /// `clipboard` reads the text of the clipboard for `[X]`; without `clipboardChangeCount` it is read
    /// again for every preview.
    internal init(
        kernel: Kernel,
        items: [FileItem],
        store: RenameStore,
        settings: RenameSettings,
        logDirectory: URL,
        previewsInBackground: Bool,
        clipboard: @escaping @Sendable () -> String?,
        clipboardChangeCount: (@MainActor () -> Int)?
    ) {
        self.kernel = kernel
        self.store = store
        self.settings = settings
        self.logDirectory = logDirectory
        self.previewsInBackground = previewsInBackground
        self.clipboard = ClipboardSource(read: clipboard, changeCount: clipboardChangeCount)
        titleRule = store.titleRule
        entries = items.map(RenameEntry.init)
        newNames = items.map(\.name)
        statuses = [RenameStatus](repeating: .unchanged, count: items.count)
        refresh()
        // The runs that can be undone are decoded in the background, ready for the button.
        if previewsInBackground {
            store.loadUndo {
                // The button asks for them when it is pressed.
            }
        }
    }

    /// The row at `index`.
    internal func row(at index: Int) -> Row {
        Row(entry: entries[index], newName: newNames[index], status: statuses[index])
    }

    /// What the masks need besides the items, with the clipboard and the dates in pictures read
    /// through `cache` when a mask asks for them.
    internal func makeContext(cache: RenameCache) -> RenameContext {
        var context = RenameContext()
        context.opened = opened
        context.changed = optionsChanged
        // Read when a mask uses it (on the main thread, asked for by a queue of the session), and
        // only if the clipboard changed.
        let snapshot = clipboard.snapshot()
        context.clipboardLoader = { snapshot.value() }
        context.environment = environment
        context.titleRule = titleRule
        context.contentDate = { subject in subject.url.flatMap { cache.contentDate(of: $0) } }
        return context
    }

    /// Computes the preview again.
    ///
    /// With a window, in the background; `onChange` follows.
    internal func refresh() {
        refreshRequest += 1
        previewCancellation.cancel()
        let cancellation = CancellationFlag()
        previewCancellation = cancellation
        let current = cache
        let request = RenameRequest(
            entries: entries,
            settings: settings,
            context: makeContext(cache: current),
            given: givenNames
        )
        let fileSystems = kernel.fileSystems
        @Sendable
        func compute() -> RenamePreview {
            RenameComputation.preview(
                request,
                fileSystems: fileSystems,
                cache: current,
                cancellation: cancellation
            ) { cancellation.isCancelled }
        }
        guard previewsInBackground else {
            let preview = compute()
            apply(preview, counts: preview.counts)
            return
        }
        isComputing = true
        queue.async { [weak self] in
            guard !cancellation.isCancelled else {
                return
            }
            let preview = autoreleasepool { compute() }
            // Counted here: the main thread does not walk the list for it.
            let counted = preview.counts
            DispatchQueue.main.async { [weak self] in
                guard let self, previewCancellation === cancellation, !cancellation.isCancelled else {
                    return
                }
                isComputing = false
                apply(preview, counts: counted)
            }
        }
    }

    /// The window was closed: the preview under way, and one waiting out the pause, are not wanted.
    internal func close() {
        previewCancellation.cancel()
        refreshRequest += 1
        isComputing = false
        onChange = nil
    }

    /// The list changed.
    ///
    /// A cache is made again for the new list; with `keepingFolders` what was found out about the
    /// folders, and the dates in pictures, are taken along (the same items in another order, or
    /// fewer).
    internal func listChanged(keepingFolders: Bool) {
        listGeneration += 1
        cache = keepingFolders ? cache.forChangedOrder() : RenameCache()
        onChange?()
        refresh()
    }

    /// A change of the fields: the preview is started after a short pause, so that typing a
    /// mask starts one preview and not one per key.
    ///
    /// Without background work it is made at once.
    private func scheduleRefresh() {
        guard previewsInBackground else {
            refresh()
            return
        }
        previewCancellation.cancel()
        isComputing = true
        refreshRequest += 1
        let request = refreshRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingPause) { [weak self] in
            guard let self, refreshRequest == request else {
                return
            }
            refresh()
        }
    }

    /// Takes in a preview of the list as it is, with its counts: one of an older list was dropped on the way.
    private func apply(_ preview: RenamePreview, counts: RenamePreview.Counts) {
        newNames = preview.names
        statuses = preview.statuses
        self.counts = counts
        problem = preview.problem
        onChange?()
    }

    deinit {
        // Nothing to release: the jobs hold the session while they run.
    }
}
