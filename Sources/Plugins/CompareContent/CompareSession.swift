import AFMContracts
import AFMKernel
import Foundation

/// Everything a "Compare contents" window does, without the window: the two files, the
/// options, the loaded contents with their differences, the edits and saving
/// (spec 09 › Compare by content).
///
/// The window draws this and forwards clicks and keys.
///
/// **Threading.** The session belongs to the main thread. Loading and comparing run on a
/// background queue and come back to the main thread with a finished value; a newer request
/// cancels the older one, whose result is then dropped. Saving runs as a job of the kernel's
/// job service. With `runsInline` (tests) the background work runs on the calling thread.
@MainActor
internal final class CompareSession {
    /// What the session is doing.
    internal enum Phase {
        /// Nothing is loaded: no files chosen, identical files, or files that could not be read.
        case empty
        /// The files are loaded and compared; the rows can be shown.
        case ready
        /// Loading or comparing runs in the background.
        case working
    }

    /// Steps kept for Undo.
    internal static let undoDepth = 100
    /// How many rows keep their worked-out inline differences before the cache starts afresh.
    internal static let inlineCacheLimit = 4_096
    /// Texts of fewer lines than this, none of them long, are compared again at once after an edit;
    /// anything larger goes to the background, so that no work grows with the size of the files on the main thread.
    private static let inlineRecompareBelow = 2_000
    /// The longest line, in UTF-16 units, of a text that is compared again at once after an edit.
    private static let inlineRecompareWidth = 1_000

    /// Unowned: the kernel owns the plugin, and through it this.
    ///
    /// Read only on the way of a request (a command, a click); what comes back later uses the parts
    /// taken when it began, for the kernel may have gone by then (a window closed, the end of a
    /// test).
    internal unowned let kernel: Kernel
    /// The settings of Compare by content (below `compareContent.`).
    private let settings: any SettingsStore
    /// The kernel's file systems, through which the files are read and saved.
    internal let fileSystems: FileSystemRegistry

    /// The first file; nil until one is chosen.
    internal var leftURL: URL?
    /// The second file; nil until one is chosen.
    internal var rightURL: URL?
    /// What counts as a difference between two lines.
    internal var options: DiffOptions
    /// "Binary": hex comparison also for text files.
    internal var forceBinary = false
    /// How many bytes make a row in binary mode.
    internal var bytesPerLine: Int
    /// Whether the background work runs on the calling thread instead (tests).
    internal var runsInline = false
    /// Which files are checked for being identical first, and which are too large to be shown.
    internal var limits = CompareLoader.Limits.standard
    /// Called on the main thread whenever something the window shows has changed.
    internal var onChange: () -> Void = {
        // Nobody listens until the window does.
    }

    /// What the session is doing.
    internal private(set) var phase = Phase.empty
    /// The two files as loaded, with their differences.
    internal var content = CompareContent.empty {
        didSet { inlineCache.removeAll() }
    }
    /// Whether the two files loaded last have the same bytes.
    internal private(set) var isIdentical = false
    /// The line under the panes: what was found, or what is going on.
    internal private(set) var status = ""
    /// Whether the texts can be edited (texts only).
    internal private(set) var isEditing = false
    /// Which sides have edits that are not saved.
    internal var modified: (left: Bool, right: Bool) = (false, false)
    /// Lines the user said belong together ("Resync comparison from here"), by line index on each side.
    internal var anchors: [(left: Int, right: Int)] = []

    /// The edits that Undo takes back, the last one at the end, each with which sides were modified before it.
    internal var undoStack: [(splices: [Splice], modified: (left: Bool, right: Bool))] = []
    /// Whether the rows shown belong to the texts held (false from an edit until the new comparison has come).
    internal var diffIsCurrent = true
    /// The files as they were when loaded, for saving (see `ComparedFiles`).
    internal var loaded: (left: FileItem?, right: FileItem?) = (nil, nil)
    /// The cancellation of the load or comparison that runs; nil when none does.
    private var running: CancellationFlag?
    /// Counts the edits, so that a save that finishes later can tell whether the text moved on meanwhile.
    internal var editGeneration = 0
    /// The parts of changed rows that differ inside the line, by row: worked out once for both
    /// sides, since the table asks for each side on every scroll.
    ///
    /// Emptied with every new `content`.
    internal var inlineCache: [Int: (left: [Range<Int>], right: [Range<Int>])] = [:]
    /// Counts the changes that make a search in progress stale (new texts, new rows, a newer search).
    internal var findGeneration = 0
    /// The cancellation of the search in the background; nil when none runs.
    internal var searching: CancellationFlag?

    /// Whether either side has edits that are not saved.
    internal var hasUnsavedChanges: Bool { modified.left || modified.right }
    /// Whether there is an edit to take back.
    internal var canUndo: Bool { !undoStack.isEmpty }

    /// A session without files, its options read from the settings.
    internal init(kernel: Kernel) {
        self.kernel = kernel
        settings = kernel.settings.scoped(to: CompareSettingsKey.scope)
        fileSystems = kernel.fileSystems
        options = DiffOptions(
            ignoreCase: settings.flag(CompareSettingsKey.ignoreCase, default: true),
            ignoreRepeatedSpaces: settings.flag(CompareSettingsKey.ignoreSpaces, default: true),
            ignoreLineEndings: settings.flag(CompareSettingsKey.ignoreLineEndings, default: true)
        )
        let choice = settings.index(CompareSettingsKey.bytesPerLine, default: 1)
        bytesPerLine = CompareSettingsKey.bytesPerLineChoices[max(0, min(3, choice))]
    }

    /// The path of a side's file as the user would type it; empty without a file.
    internal func displayPath(_ side: CompareSide) -> String {
        (side == .left ? leftURL : rightURL).map(fileSystems.displayPath) ?? ""
    }

    // MARK: Loading and comparing

    /// Runs `work` away from the main thread and hands its result to `finish` on it, unless a
    /// newer request has come in meanwhile.
    private func background<Value: Sendable>(
        _ work: @escaping @Sendable (CancellationFlag) -> Value,
        finish: @escaping @MainActor (Value, _ wasCancelled: Bool) -> Void
    ) {
        running?.cancel()
        // A search in progress belongs to the texts and rows that are about to change.
        findGeneration += 1
        let cancellation = CancellationFlag()
        running = cancellation
        phase = .working
        status = "Comparing…"
        onChange()
        if runsInline {
            finish(work(cancellation), cancellation.isCancelled)
            return
        }
        // A thread of its own, not a worker of the shared pool: loading from a share that does not
        // answer can block for a long time, and a few such loads must not use up the pool.
        CompareWorker.run("Compare") { [weak self] in
            let value = work(cancellation)
            DispatchQueue.main.async { [weak self] in
                guard let self, running === cancellation else {
                    return
                }
                finish(value, cancellation.isCancelled)
            }
        }
    }

    /// Loads the two files and compares them, with nothing to tell back.
    internal func compare() {
        compare { _ in
            // The window shows what came.
        }
    }

    /// Loads the two files and compares them.
    ///
    /// Identical files are announced with the message of the spec (09 › Opening and choosing the
    /// files); `completion` tells whether there is something to show.
    internal func compare(completion: @escaping (_ hasContent: Bool) -> Void) {
        guard let leftURL, let rightURL else {
            content = .empty
            phase = .empty
            status = "Choose two files and press Compare"
            onChange()
            completion(false)
            return
        }
        background(
            { [fileSystems, forceBinary, options, bytesPerLine, limits] cancellation in
                CompareLoader.load(
                    left: leftURL,
                    right: rightURL,
                    fileSystems: fileSystems,
                    forceBinary: forceBinary,
                    options: options,
                    bytesPerLine: bytesPerLine,
                    cancellation: cancellation,
                    limits: limits
                )
            },
            finish: { [self, interaction = kernel.interaction] result, wasCancelled in
                running = nil
                if wasCancelled || result.wasCancelled {
                    keepAfterCancel()
                    completion(false)
                    return
                }
                install(result, interaction: interaction)
                completion(!result.content.isEmpty)
            }
        )
    }

    /// What a cancelled load leaves: the cut-short result is not installed, and what was shown before stays.
    ///
    /// If that was edited and its comparison had been given up for the load, it is made again, so that the rows
    /// shown and the texts held agree before anything is edited or copied.
    private func keepAfterCancel() {
        status = "Cancelled"
        if !content.isEmpty, !diffIsCurrent {
            recompute()
        } else {
            phase = content.isEmpty ? .empty : .ready
            onChange()
        }
    }

    /// Shows newly loaded files: their content, their state, and a message for identical or unreadable files.
    private func install(_ result: ComparedFiles, interaction: any UserInteraction) {
        content = result.content
        diffIsCurrent = true
        loaded = (result.leftItem, result.rightItem)
        isIdentical = result.isIdentical
        modified = (false, false)
        anchors = []
        undoStack = []
        phase = .ready
        updateStatus()
        if let message = result.message {
            status = message
            interaction.inform("Compare contents", detail: message, style: .warning)
        } else if result.isIdentical {
            interaction.inform(
                "Compare contents",
                detail: "The two files have the same content!",
                style: .information
            )
        }
        onChange()
    }

    /// Compares what is loaded again, after an option or the texts changed.
    internal func recompute() {
        findGeneration += 1
        switch content {
        case .empty:
            return

        case .binary(let left, let right, _):
            background(
                { [bytesPerLine] cancellation in
                    BinaryDiff.compute(left: left, right: right, bytesPerLine: bytesPerLine, cancellation: cancellation)
                },
                finish: { [self] diff, cancelled in
                    show(.binary(left: left, right: right, diff: diff), cancelled: cancelled)
                }
            )

        case .text(let left, let right, _, let width):
            let work: @Sendable (CancellationFlag?) -> CompareContent = { [options, anchors] cancellation in
                CompareLoader.text(
                    left: left,
                    right: right,
                    options: options,
                    anchors: anchors,
                    cancellation: cancellation
                )
            }
            if left.lines.count + right.lines.count < Self.inlineRecompareBelow,
                width <= Self.inlineRecompareWidth
            {
                running?.cancel()
                show(work(nil), cancelled: false)
            } else {
                background(
                    { cancellation in work(cancellation) },
                    finish: { [self] compared, cancelled in show(compared, cancelled: cancelled) }
                )
            }
        }
    }

    /// Shows a new comparison of the texts or bytes held; `cancelled` marks it incomplete.
    private func show(_ content: CompareContent, cancelled: Bool) {
        running = nil
        self.content = content
        diffIsCurrent = true
        phase = .ready
        updateStatus()
        if cancelled {
            status = "Cancelled: the differences shown are incomplete"
        }
        onChange()
    }

    /// Edit mode exists for texts only (spec 09 › Edit mode and saving).
    internal func setEditing(_ editing: Bool) {
        isEditing = editing && !isBinary
        onChange()
    }

    /// Gives the edits up (the user chose not to save them).
    internal func discardChanges() {
        modified = (false, false)
    }

    /// Stops the load, comparison or search that runs; what it would have shown is dropped.
    internal func cancel() {
        running?.cancel()
        searching?.cancel()
    }

    /// The options were changed in the window: they are remembered and applied.
    internal func optionsChanged() {
        settings.set(options.ignoreCase, forKey: CompareSettingsKey.ignoreCase)
        settings.set(options.ignoreRepeatedSpaces, forKey: CompareSettingsKey.ignoreSpaces)
        settings.set(options.ignoreLineEndings, forKey: CompareSettingsKey.ignoreLineEndings)
        settings.set(
            CompareSettingsKey.bytesPerLineChoices.firstIndex(of: bytesPerLine) ?? 1,
            forKey: CompareSettingsKey.bytesPerLine
        )
        recompute()
    }

    /// Sets the status line to what the content shows: how many differences, the encodings, the state of edits.
    internal func updateStatus() {
        switch content {
        case .empty:
            status = isIdentical ? "The two files have the same content!" : ""

        case .text(let left, let right, let diff, _):
            let count = diff.blocks.count
            let differences =
                count == 0
                ? (isIdentical ? "The two files have the same content!" : "No differences with the current options")
                : "\(count) difference\(count == 1 ? "" : "s")"
            status =
                "\(differences)    \(left.encoding.name) <-> \(right.encoding.name)"
                + (hasUnsavedChanges ? "    [modified]" : "") + (anchors.isEmpty ? "" : "    [resynchronized]")

        case .binary(_, _, let diff):
            let count = diff.blocks.count
            status =
                diff.isIdentical
                ? "The two files have the same content!"
                : "\(count) difference\(count == 1 ? "" : "s"), "
                    + "\(Format.bytes(Int64(diff.differingBytes))) bytes differ    binary"
        }
    }

    deinit {
        // Nothing to release.
    }
}
