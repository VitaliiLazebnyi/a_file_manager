import AFMContracts
import AFMKernel
import Foundation

enum CompareSide {
    case left, right

    var other: Self { self == .left ? .right : .left }
}

/// The settings keys of Compare by content, all below `compareContent.`.
enum CompareSettingsKey {
    static let scope = "compareContent"
    static let ignoreCase = "ignoreCase"
    static let ignoreSpaces = "ignoreRepeatedSpaces"
    static let ignoreLineEndings = "ignoreLineEndings"
    static let vertical = "vertical"
    static let bytesPerLine = "bytesPerLine"
    static let fontName = "fontName"
    static let fontSize = "fontSize"
    static let bytesPerLineChoices = [8, 16, 24, 32]
}

/// Everything a "Compare contents" window does, without the window: the two files, the
/// options, the loaded contents with their differences, the edits and saving
/// (spec 09 › Compare by content). The window draws this and forwards clicks and keys.
///
/// **Threading.** The session belongs to the main thread. Loading and comparing run on a
/// background queue and come back to the main thread with a finished value; a newer request
/// cancels the older one, whose result is then dropped. Saving runs as a job of the kernel's
/// job service. With `runsInline` (tests) the background work runs on the calling thread.
@MainActor
final class CompareSession {
    enum Phase {
        case empty, working, ready
    }

    let kernel: Kernel
    private let settings: any SettingsStore

    var leftURL: URL?
    var rightURL: URL?
    var options: DiffOptions
    /// "Binary": hex comparison also for text files.
    var forceBinary = false
    var bytesPerLine: Int
    var runsInline = false
    /// Called on the main thread whenever something the window shows has changed.
    var onChange: () -> Void = {}

    private(set) var phase = Phase.empty
    private(set) var content = CompareContent.none {
        didSet { inlineCache.removeAll() }
    }
    private(set) var isIdentical = false
    private(set) var status = ""
    private(set) var isEditing = false
    private(set) var modified: (left: Bool, right: Bool) = (false, false)
    private(set) var anchors: [(left: Int, right: Int)] = []

    /// One change to the lines of one side: `removed` stood at `start`, and `insertedCount` lines stand there now.
    /// Undo puts the removed lines back; nothing of the files is copied for it.
    private struct Splice {
        var side: CompareSide
        var start: Int
        var removed: [TextLine]
        var insertedCount: Int
    }

    private var undoStack: [(splices: [Splice], modified: (left: Bool, right: Bool))] = []
    /// Steps kept for Undo.
    private static let undoDepth = 100
    /// Whether the rows shown belong to the texts held (false from an edit until the new comparison has come).
    private var diffIsCurrent = true
    /// The files as they were when loaded, for saving (see `ComparedFiles`).
    private var loaded: (left: FileItem?, right: FileItem?) = (nil, nil)
    private var running: CancellationFlag?
    /// Counts the edits, so that a save that finishes later can tell whether the text moved on meanwhile.
    private var editGeneration = 0
    /// The parts of changed rows that differ inside the line, by row: worked out once for both
    /// sides, since the table asks for each side on every scroll. Emptied with every new `content`.
    private var inlineCache: [Int: (left: [Range<Int>], right: [Range<Int>])] = [:]
    private static let inlineCacheLimit = 4_096
    private var findGeneration = 0
    /// Texts of fewer lines than this, none of them long, are compared again at once after an edit;
    /// anything larger goes to the background, so that no work grows with the size of the files on the main thread.
    private static let inlineRecompareBelow = 2_000
    private static let inlineRecompareWidth = 1_000

    init(kernel: Kernel) {
        self.kernel = kernel
        settings = kernel.settings.scoped(to: CompareSettingsKey.scope)
        options = DiffOptions(
            ignoreCase: settings.flag(CompareSettingsKey.ignoreCase, default: true),
            ignoreRepeatedSpaces: settings.flag(CompareSettingsKey.ignoreSpaces, default: true),
            ignoreLineEndings: settings.flag(CompareSettingsKey.ignoreLineEndings, default: true))
        let choice = settings.index(CompareSettingsKey.bytesPerLine, default: 1)
        bytesPerLine = CompareSettingsKey.bytesPerLineChoices[max(0, min(3, choice))]
    }

    private var fileSystems: FileSystemRegistry { kernel.fileSystems }
    var hasUnsavedChanges: Bool { modified.left || modified.right }
    var canUndo: Bool { !undoStack.isEmpty }

    func displayPath(_ side: CompareSide) -> String {
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
                guard let self, self.running === cancellation else { return }
                finish(value, cancellation.isCancelled)
            }
        }
    }

    /// Loads the two files and compares them. Identical files are announced with the message
    /// of the spec (09 › Opening and choosing the files); `completion` tells whether there is
    /// something to show.
    func compare(completion: @escaping (_ hasContent: Bool) -> Void = { _ in }) {
        guard let leftURL, let rightURL else {
            content = .none
            phase = .empty
            status = "Choose two files and press Compare"
            onChange()
            completion(false)
            return
        }
        let (fileSystems, forceBinary, options, bytesPerLine) = (
            self.fileSystems, self.forceBinary, self.options, self.bytesPerLine
        )
        background(
            { cancellation in
                CompareLoader.load(
                    left: leftURL, right: rightURL, forceBinary: forceBinary, options: options,
                    bytesPerLine: bytesPerLine,
                    fileSystems: fileSystems, cancellation: cancellation)
            },
            finish: { [self] result, wasCancelled in
                running = nil
                if wasCancelled || result.wasCancelled {
                    // The cut-short result is not installed: what was shown before stays. If that was
                    // edited and its comparison had been given up for this one, it is made again, so
                    // that the rows shown and the texts held agree before anything is edited or copied.
                    status = "Cancelled"
                    if !content.isNone, !diffIsCurrent {
                        recompute()
                    } else {
                        phase = content.isNone ? .empty : .ready
                        onChange()
                    }
                    completion(false)
                    return
                }
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
                    kernel.ui.inform("Compare contents", detail: message, style: .warning)
                } else if result.isIdentical {
                    kernel.ui.inform(
                        "Compare contents", detail: "The two files have the same content!", style: .information)
                }
                onChange()
                if case .none = result.content { completion(false) } else { completion(true) }
            })
    }

    /// Compares what is loaded again, after an option or the texts changed.
    func recompute() {
        findGeneration += 1
        switch content {
        case .none:
            return

        case .binary(let left, let right, _):
            let bytesPerLine = self.bytesPerLine
            background(
                { BinaryDiff.compute(left: left, right: right, bytesPerLine: bytesPerLine, cancellation: $0) },
                finish: { [self] diff, cancelled in
                    show(.binary(left: left, right: right, diff: diff), cancelled: cancelled)
                })

        case .text(let left, let right, _, let width):
            let (options, anchors) = (self.options, self.anchors)
            let work: @Sendable (CancellationFlag?) -> CompareContent = { cancellation in
                CompareLoader.text(
                    left: left, right: right, options: options, anchors: anchors, cancellation: cancellation)
            }
            if left.lines.count + right.lines.count < Self.inlineRecompareBelow,
                width <= Self.inlineRecompareWidth
            {
                running?.cancel()
                show(work(nil))
            } else {
                background({ work($0) }, finish: { [self] in show($0, cancelled: $1) })
            }
        }
    }

    private func show(_ content: CompareContent, cancelled: Bool = false) {
        running = nil
        self.content = content
        diffIsCurrent = true
        phase = .ready
        updateStatus()
        if cancelled { status = "Cancelled: the differences shown are incomplete" }
        onChange()
    }

    /// Gives the edits up (the user chose not to save them).
    func discardChanges() {
        modified = (false, false)
    }

    func cancel() {
        running?.cancel()
        searching?.cancel()
    }

    /// The options were changed in the window: they are remembered and applied.
    func optionsChanged() {
        settings.set(options.ignoreCase, forKey: CompareSettingsKey.ignoreCase)
        settings.set(options.ignoreRepeatedSpaces, forKey: CompareSettingsKey.ignoreSpaces)
        settings.set(options.ignoreLineEndings, forKey: CompareSettingsKey.ignoreLineEndings)
        settings.set(
            CompareSettingsKey.bytesPerLineChoices.firstIndex(of: bytesPerLine) ?? 1,
            forKey: CompareSettingsKey.bytesPerLine)
        recompute()
    }

    private func updateStatus() {
        switch content {
        case .none:
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
            status =
                diff.isIdentical
                ? "The two files have the same content!"
                : "\(diff.blocks.count) difference\(diff.blocks.count == 1 ? "" : "s"), \(Format.bytes(Int64(diff.differingBytes))) bytes differ    binary"
        }
    }

    // MARK: Rows

    var isBinary: Bool {
        if case .binary = content { return true }
        return false
    }

    var rowCount: Int {
        switch content {
        case .none: return 0
        case .text(_, _, let diff, _): return diff.rows.count
        case .binary(_, _, let diff): return diff.rowCount
        }
    }

    /// The differences as ranges of rows.
    var blocks: [Range<Int>] {
        switch content {
        case .none: return []
        case .text(_, _, let diff, _): return diff.blocks
        case .binary(_, _, let diff): return diff.blocks
        }
    }

    /// The length of the longest line in characters, for the width of the panes.
    var width: Int {
        switch content {
        case .none: return 0
        case .text(_, _, _, let width): return width
        case .binary(_, _, let diff): return diff.bytesPerLine * 4 + 1
        }
    }

    /// The difference a row belongs to, found by halving.
    func block(containing row: Int) -> Range<Int>? {
        let blocks = self.blocks
        var (low, high) = (0, blocks.count)
        while low < high {
            let middle = (low + high) / 2
            if blocks[middle].upperBound <= row { low = middle + 1 } else { high = middle }
        }
        return low < blocks.count && blocks[low].contains(row) ? blocks[low] : nil
    }

    func kind(ofRow row: Int) -> DiffRow.Kind {
        switch content {
        case .none: return .equal
        case .text(_, _, let diff, _): return diff.rows.indices.contains(row) ? diff.rows[row].kind : .equal
        case .binary: return block(containing: row) == nil ? .equal : .changed
        }
    }

    private func line(_ side: CompareSide, row: Int) -> TextLine? {
        guard case .text(let left, let right, let diff, _) = content, diff.rows.indices.contains(row) else {
            return nil
        }
        let (document, index) = side == .left ? (left, diff.rows[row].left) : (right, diff.rows[row].right)
        return index.flatMap { document.lines.indices.contains($0) ? document.lines[$0] : nil }
    }

    /// What stands in front of a row: the line number (0 for a new or changed line), or the
    /// offset in binary mode. Empty where the side has no line.
    func label(_ side: CompareSide, row: Int) -> String {
        switch content {
        case .none: return ""
        case .text: return line(side, row: row).map { String($0.number) } ?? ""

        case .binary(let left, let right, let diff):
            return row * diff.bytesPerLine < (side == .left ? left.count : right.count) ? diff.offsetText(row: row) : ""
        }
    }

    /// The text of a row on one side; nil where the side has no line.
    func text(_ side: CompareSide, row: Int) -> String? {
        switch content {
        case .none: return nil
        case .text: return line(side, row: row)?.text

        case .binary(let left, let right, let diff):
            let text = diff.text(of: side == .left ? left : right, row: row)
            return text.isEmpty ? nil : text
        }
    }

    /// The parts of a row's text that differ from the other side, in UTF-16 units.
    func highlights(_ side: CompareSide, row: Int) -> [Range<Int>] {
        switch content {
        case .none: return []

        case .text:
            guard kind(ofRow: row) == .changed, let left = line(.left, row: row), let right = line(.right, row: row)
            else { return [] }
            let ranges: (left: [Range<Int>], right: [Range<Int>])
            if let cached = inlineCache[row] {
                ranges = cached
            } else {
                ranges = TextDiff.inline(left.text, right.text)
                if inlineCache.count >= Self.inlineCacheLimit { inlineCache.removeAll() }
                inlineCache[row] = ranges
            }
            return side == .left ? ranges.left : ranges.right

        case .binary(let left, let right, let diff):
            guard kind(ofRow: row) == .changed else { return [] }
            return diff.differingOffsets(left: left, right: right, row: row).flatMap(diff.textRanges)
        }
    }

    /// The first row of the next (or previous) difference as seen from `row`.
    func difference(from row: Int, forward: Bool) -> Int? {
        forward ? blocks.first { $0.lowerBound > row }?.lowerBound : blocks.last { $0.lowerBound < row }?.lowerBound
    }

    /// The next row, in either file, whose text contains `needle`, ignoring case; the search
    /// goes round at the ends. Blocks: for callers that are not the window.
    func find(_ needle: String, from row: Int, forward: Bool) -> Int? {
        Self.search(content, needle, from: row, forward: forward, cancellation: nil)
    }

    /// The same away from the main thread, so that a large file does not freeze the window; a
    /// newer search (or `cancel`) makes the older one stop and drops its answer.
    func find(_ needle: String, from row: Int, forward: Bool, completion: @escaping @MainActor (Int?) -> Void) {
        findGeneration += 1
        let generation = findGeneration
        let (content, cancellation) = (self.content, CancellationFlag())
        searching?.cancel()
        searching = cancellation
        if runsInline {
            completion(Self.search(content, needle, from: row, forward: forward, cancellation: nil))
            return
        }
        CompareWorker.run("Compare find") { [weak self] in
            let found = Self.search(content, needle, from: row, forward: forward, cancellation: cancellation)
            DispatchQueue.main.async { [weak self] in
                // Stale when another search started, or the texts changed, meanwhile.
                guard let self, !cancellation.isCancelled, self.findGeneration == generation else { return }
                self.searching = nil
                completion(found)
            }
        }
    }

    private var searching: CancellationFlag?

    nonisolated private static func search(
        _ content: CompareContent, _ needle: String, from row: Int, forward: Bool, cancellation: CancellationFlag?
    ) -> Int? {
        let count: Int
        let sides: (Int, CompareSide) -> String?
        switch content {
        case .none:
            return nil

        case .text(let left, let right, let diff, _):
            count = diff.rows.count
            sides = { candidate, side in
                let (document, index) =
                    side == .left ? (left, diff.rows[candidate].left) : (right, diff.rows[candidate].right)
                return index.flatMap { document.lines.indices.contains($0) ? document.lines[$0].text : nil }
            }

        case .binary(let left, let right, let diff):
            count = diff.rowCount
            sides = { candidate, side in
                let text = diff.text(of: side == .left ? left : right, row: candidate)
                return text.isEmpty ? nil : text
            }
        }
        guard count > 0, !needle.isEmpty else { return nil }
        for step in 1...count {
            if step & 0x3FF == 0, cancellation?.isCancelled == true { return nil }
            let candidate = ((row + (forward ? step : -step)) % count + count) % count
            for side in [CompareSide.left, .right]
            where sides(candidate, side)?.range(of: needle, options: .caseInsensitive) != nil {
                return candidate
            }
        }
        return nil
    }

    // MARK: Resync and swap

    /// "Resync comparison from here": the lines of the two rows are taken to belong together.
    func resync(leftRow: Int, rightRow: Int) {
        guard case .text(_, _, let diff, _) = content, diff.rows.indices.contains(leftRow),
            diff.rows.indices.contains(rightRow),
            let left = diff.rows[leftRow].left, let right = diff.rows[rightRow].right
        else { return }
        // Anchors that the new one crosses are given up.
        anchors.removeAll { ($0.left < left) != ($0.right < right) || $0.left == left || $0.right == right }
        anchors.append((left, right))
        recompute()
    }

    func clearResync() {
        guard !anchors.isEmpty else { return }
        anchors = []
        recompute()
    }

    /// Swap panels (Ctrl+U): left becomes right.
    func swap() {
        (leftURL, rightURL) = (rightURL, leftURL)
        loaded = (loaded.right, loaded.left)
        modified = (modified.right, modified.left)
        findGeneration += 1
        anchors = anchors.map { ($0.right, $0.left) }
        undoStack = []
        switch content {
        case .none: onChange()

        case .text(let left, let right, _, _):
            content = .text(left: right, right: left, diff: TextDiff(rows: [], blocks: []), width: 0)
            diffIsCurrent = false
            recompute()

        case .binary(let left, let right, _):
            content = .binary(left: right, right: left, diff: BinaryDiff.compute(left: Data(), right: Data()))
            recompute()
        }
    }

    // MARK: Editing

    /// Edit mode exists for texts only (spec 09 › Edit mode and saving).
    func setEditing(_ editing: Bool) {
        isEditing = editing && !isBinary
        onChange()
    }

    /// Applies an edit in place and remembers what it replaced. The texts are taken out of `content`
    /// first, so that nothing else holds their lines and they are changed where they are: an edit in
    /// a file of millions of lines does not copy it.
    private func edit(_ change: (inout TextDocument, inout TextDocument, TextDiff) -> [Splice]) {
        guard isEditing, phase == .ready, diffIsCurrent, case .text(var left, var right, let diff, let width) = content
        else { return }
        content = .none
        let splices = change(&left, &right, diff)
        guard !splices.isEmpty else {
            content = .text(left: left, right: right, diff: diff, width: width)
            return
        }
        let touched = (left: splices.contains { $0.side == .left }, right: splices.contains { $0.side == .right })
        undoStack.append((splices, modified))
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        editGeneration += 1
        findGeneration += 1
        modified = (modified.left || touched.left, modified.right || touched.right)
        // Line positions have moved, so the forced pairs no longer mean anything.
        anchors = []
        content = .text(left: left, right: right, diff: diff, width: width)
        diffIsCurrent = false
        recompute()
    }

    /// Replaces the text of a row's line on one side, as typed in the pane.
    func setText(_ text: String, _ side: CompareSide, row: Int) {
        edit { left, right, diff in
            guard diff.rows.indices.contains(row),
                let index = side == .left ? diff.rows[row].left : diff.rows[row].right
            else { return [] }
            let apply = { (document: inout TextDocument) -> [Splice] in
                guard document.lines.indices.contains(index), document.lines[index].text != text else { return [] }
                let old = document.lines[index]
                document.lines[index].text = text
                document.lines[index].number = 0
                return [Splice(side: side, start: index, removed: [old], insertedCount: 1)]
            }
            return side == .left ? apply(&left) : apply(&right)
        }
    }

    /// "Copy ->" / "Copy <-": the lines of the given rows on the other side replace those on
    /// `side`. Rows that have no line on the source side remove the target's lines.
    func copy(rows: Range<Int>, to side: CompareSide) {
        edit { left, right, diff in
            let rows = rows.clamped(to: 0..<diff.rows.count)
            guard !rows.isEmpty else { return [] }
            func index(_ row: DiffRow, _ of: CompareSide) -> Int? { of == .left ? row.left : row.right }
            let source = side == .left ? right : left
            var target = side == .left ? left : right
            // Lines arrive with the line break the target file mostly uses, so a file keeps one
            // style (spec 09 › Edit mode and saving); an empty target takes the source's.
            let ending =
                target.lines.contains { $0.ending != .none }
                ? target.usualEnding(sampleLimit: 10_000) : source.usualEnding(sampleLimit: 10_000)
            // The rows were made from these texts; an index outside them is skipped, never trusted.
            let incoming = diff.rows[rows].compactMap { index($0, side.other) }.filter {
                source.lines.indices.contains($0)
            }
            .map { TextLine(source.lines[$0].text, ending: ending, number: 0) }
            let replaced = diff.rows[rows].compactMap { index($0, side) }.filter { target.lines.indices.contains($0) }
            // Where nothing is replaced, the lines go in before the target's next line.
            let start =
                replaced.first ?? diff.rows[rows.upperBound...].lazy.compactMap { index($0, side) }.first
                ?? target.lines.count
            let range = start..<(start + replaced.count)
            guard range.upperBound <= target.lines.count, Array(target.lines[range]).map(\.text) != incoming.map(\.text)
            else { return [] }
            let splice = Splice(
                side: side, start: start, removed: Array(target.lines[range]), insertedCount: incoming.count)
            // Released before the change, so that it is made in the lines of the document itself.
            target = TextDocument()
            if side == .left {
                left.lines.replaceSubrange(range, with: incoming)
            } else {
                right.lines.replaceSubrange(range, with: incoming)
            }
            return [splice]
        }
    }

    func undo() {
        guard isEditing, case .text(var left, var right, let diff, let width) = content, let last = undoStack.popLast()
        else { return }
        content = .none
        for splice in last.splices.reversed() {
            let range = splice.start..<(splice.start + splice.insertedCount)
            if splice.side == .left, range.upperBound <= left.lines.count {
                left.lines.replaceSubrange(range, with: splice.removed)
            } else if splice.side == .right, range.upperBound <= right.lines.count {
                right.lines.replaceSubrange(range, with: splice.removed)
            }
        }
        modified = last.modified
        editGeneration += 1
        findGeneration += 1
        anchors = []
        content = .text(left: left, right: right, diff: diff, width: width)
        diffIsCurrent = false
        recompute()
    }

    // MARK: Saving

    /// What the save job reports for one file.
    private struct Saved {
        var side: CompareSide
        var error: any Error?
        /// The file as it is after saving; what the next save is checked against.
        var item: FileItem?
    }

    /// Writes the changed files back through their file systems, as a job; `completion` tells
    /// whether everything is saved, edits made while the job ran included.
    func save(completion: @escaping (Bool) -> Void = { _ in }) {
        guard case .text(let left, let right, _, _) = content, hasUnsavedChanges else {
            completion(true)
            return
        }
        var files: [(side: CompareSide, url: URL, document: TextDocument, expected: FileItem?)] = []
        if modified.left, let leftURL { files.append((.left, leftURL, left, loaded.left)) }
        if modified.right, let rightURL { files.append((.right, rightURL, right, loaded.right)) }
        // Two edited texts of one file cannot both be written: the second would silently replace the first.
        if files.count == 2, CompareLoader.isSameFile(files[0].url, files[1].url) {
            kernel.ui.report(
                CompareLoader.SaveError.sameFile(fileSystems.displayPath(files[0].url)), title: "Nothing was saved.")
            completion(false)
            return
        }
        let fileSystems = self.fileSystems
        let generation = editGeneration
        kernel.jobs.run(
            title: "Save",
            work: { [files] monitor -> [Saved] in
                files.enumerated().map { index, file in
                    monitor.report(
                        JobProgress(
                            lines: ["Save: " + fileSystems.displayPath(file.url)], itemsDone: index,
                            itemsTotal: files.count))
                    do {
                        let data = try file.document.encodedData(named: file.url.lastPathComponent)
                        let item = try CompareLoader.replace(
                            file.url, with: data, expected: file.expected, fileSystems: fileSystems)
                        return Saved(side: file.side, error: nil, item: item)
                    } catch {
                        return Saved(side: file.side, error: error, item: nil)
                    }
                }
            },
            completion: { [self] results in
                for saved in results {
                    if let error = saved.error {
                        kernel.ui.report(error, title: "\(displayPath(saved.side)) could not be saved.")
                    } else {
                        // What was written is now the file on disk, whatever was edited since.
                        if saved.side == .left {
                            loaded.left = saved.item?.isSymlink == true ? nil : saved.item
                        } else {
                            loaded.right = saved.item?.isSymlink == true ? nil : saved.item
                        }
                        // Only what was saved is settled: an edit made while the job ran is still unsaved.
                        if editGeneration == generation {
                            if saved.side == .left { modified.left = false } else { modified.right = false }
                        }
                    }
                }
                kernel.panels.refresh(files.map { $0.url.deletingLastPathComponent() })
                updateStatus()
                onChange()
                completion(results.allSatisfy { $0.error == nil } && !hasUnsavedChanges)
            })
    }

    /// Writes the changed files at once on the calling thread, for the program quitting, where a
    /// job can no longer be waited for. Returns whether everything was saved; errors are reported.
    func saveNow() -> Bool {
        guard case .text(let left, let right, _, _) = content, hasUnsavedChanges else { return true }
        var ok = true
        for (side, url, document, expected, isModified) in [
            (CompareSide.left, leftURL, left, loaded.left, modified.left),
            (.right, rightURL, right, loaded.right, modified.right)
        ] where isModified {
            guard let url else { continue }
            do {
                let data = try document.encodedData(named: url.lastPathComponent)
                try CompareLoader.replace(url, with: data, expected: expected, fileSystems: fileSystems)
                if side == .left { modified.left = false } else { modified.right = false }
            } catch {
                ok = false
                kernel.ui.report(error, title: "\(fileSystems.displayPath(url)) could not be saved.")
            }
        }
        return ok
    }
}

/// Where the session's loading, comparing and searching run: a thread of their own for each, never
/// a worker of the shared pool. Reading from a share that does not answer can block for as long as the
/// server takes to give up; a handful of those must not use up the workers that everything else needs.
enum CompareWorker {
    static func run(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
    }
}
