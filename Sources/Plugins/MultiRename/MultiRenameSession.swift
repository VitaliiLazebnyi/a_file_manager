import AFMContracts
import AFMKernel
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The text on the clipboard for `[X]`, read when a mask asks for it and not before, off the main
/// thread (a program that provides its text only when asked can take as long as it likes), and
/// kept until the clipboard changes. Safe to use from several threads.
final class ClipboardSource {
    /// One reading of the clipboard. Unchecked `Sendable`: the state is guarded by `condition`;
    /// `read` and `queue` do not change after `init`.
    final class Snapshot: @unchecked Sendable {
        private let condition = NSCondition()
        private var text: String?
        private var isRead = false
        private var isRequested = false
        private var gaveUpAt: Date?
        private let read: @Sendable () -> String?
        private let queue: DispatchQueue
        /// The longest text taken: a name holds a line of it at the most.
        static let longest = 1 << 16
        /// How long a mask waits for a program that does not answer.
        static let patience: TimeInterval = 2
        /// For this long after giving up, nobody waits again.
        static let grace: TimeInterval = 10

        fileprivate init(read: @escaping @Sendable () -> String?, queue: DispatchQueue) {
            self.read = read
            self.queue = queue
        }

        /// The text, or nil when there is none or the clipboard does not answer in time.
        func value() -> String? {
            condition.lock()
            if !isRequested {
                isRequested = true
                queue.async { [self] in
                    let found = read().map { String($0.prefix(Self.longest)) }
                    condition.lock()
                    (text, isRead) = (found, true)
                    condition.broadcast()
                    condition.unlock()
                }
            }
            defer { condition.unlock() }
            // A clipboard that was waited for in vain is not waited for again by every name of the list.
            if !isRead, let gaveUp = gaveUpAt, Date().timeIntervalSince(gaveUp) < Self.grace { return nil }
            let deadline = Date(timeIntervalSinceNow: Self.patience)
            while !isRead, condition.wait(until: deadline) {}
            if !isRead { gaveUpAt = Date() }
            return isRead ? text : nil
        }
    }

    private let read: @Sendable () -> String?
    private let changeCount: (() -> Int)?
    private let queue = DispatchQueue(label: "multirename.clipboard", qos: .userInitiated)
    private var last: (count: Int, snapshot: Snapshot)?

    /// Without `changeCount` the clipboard is read again for every preview.
    init(read: @escaping @Sendable () -> String?, changeCount: (() -> Int)? = nil) {
        self.read = read
        self.changeCount = changeCount
    }

    /// The clipboard as it is now. Cheap: nothing is read until the snapshot is asked for its
    /// value, and a clipboard that has not changed since the last call gives the same snapshot.
    /// Main thread.
    func snapshot() -> Snapshot {
        guard let changeCount else { return Snapshot(read: read, queue: queue) }
        let count = changeCount()
        if let last, last.count == count { return last.snapshot }
        let fresh = Snapshot(read: read, queue: queue)
        last = (count, fresh)
        return fresh
    }
}

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
final class MultiRenameSession {
    struct Row {
        var entry: RenameEntry
        /// Nil is `<Error!>`.
        var newName: String?
        var status: RenameStatus
    }

    enum SortKey {
        case name, ext, size, date
    }

    private let kernel: Kernel
    let store: RenameStore
    private let logDirectory: URL
    private let previewsInBackground: Bool
    private let clipboard: ClipboardSource
    private let environment = ProcessInfo.processInfo.environment
    private var titleRule: TitleCaseRule
    private let opened = Date()
    private var optionsChanged = Date()
    private let queue = DispatchQueue(label: "multirename.preview", qos: .userInitiated)
    /// Sorts have a queue of their own: a long one does not hold the previews up.
    private let sortQueue = DispatchQueue(label: "multirename.sort", qos: .userInitiated)
    /// Stops the preview that is under way when a newer one starts.
    private var previewCancellation = CancellationFlag()
    /// What the previews of the current list share; replaced when the list changes.
    private var cache = RenameCache()
    /// Counts the changes of the list, so that a sort that finishes late can see it was overtaken.
    private var listGeneration = 0
    /// Counts the sorts asked for: of two sorts under way, the last one is the one that counts.
    private var sortRequest = 0
    /// Counts the changes of the fields, so that a preview waiting out the pause can see it was overtaken.
    private var refreshRequest = 0

    /// The pause between the last change of a field and the preview it starts.
    static let typingPause: TimeInterval = 0.1

    /// The entries of the list, their new names and how they stand: parallel arrays, so that a
    /// preview is taken in by assigning two of them.
    private(set) var entries: [RenameEntry]
    private var newNames: [String?]
    private var statuses: [RenameStatus]
    private var givenNamesStorage: [String]?
    /// Names loaded from a file or typed by the user; they take the place of the masks.
    var givenNames: [String]? { givenNamesStorage }
    /// What is wrong with the masks or the expression, if anything.
    private(set) var problem: any Error?
    private(set) var isComputing = false
    /// A run or an Undo is under way: the list stays as it is until it is over.
    private(set) var isBusy = false
    /// The renames of the last run of this session, for the result list.
    private(set) var lastRun: [RenamedItem] = []
    /// How the items stand; worked out with the preview.
    private(set) var counts: (changing: Int, conflicts: Int, errors: Int) = (0, 0, 0)
    /// Called on the main thread whenever rows, preview or buttons may look different.
    var onChange: (() -> Void)?

    var settings: RenameSettings {
        didSet {
            guard settings != oldValue else { return }
            optionsChanged = Date()
            scheduleRefresh()
        }
    }

    init(
        kernel: Kernel, items: [FileItem], store: RenameStore, settings: RenameSettings, logDirectory: URL,
        previewsInBackground: Bool = true, clipboard: @escaping @Sendable () -> String? = { nil },
        clipboardChangeCount: (() -> Int)? = nil
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
        if previewsInBackground { store.loadUndo() }
    }

    /// The rows as the list shows them. Made on each call: ask for one row with `row(at:)`.
    var rows: [Row] { entries.indices.map(row(at:)) }
    var rowCount: Int { entries.count }

    func row(at index: Int) -> Row {
        Row(entry: entries[index], newName: newNames[index], status: statuses[index])
    }

    // MARK: Preview

    private func makeContext(cache: RenameCache) -> RenameContext {
        var context = RenameContext()
        context.opened = opened
        context.changed = optionsChanged
        // Read when a mask uses it, on a thread of the preview, and only if the clipboard changed.
        let snapshot = clipboard.snapshot()
        context.clipboardLoader = { snapshot.value() }
        context.environment = environment
        context.titleRule = titleRule
        context.contentDate = { subject in subject.url.flatMap { cache.contentDate(of: $0) } }
        return context
    }

    /// A change of the fields: the preview is started after a short pause, so that typing a
    /// mask starts one preview and not one per key. Without background work it is made at once.
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
            guard let self, refreshRequest == request else { return }
            refresh()
        }
    }

    /// Computes the preview again. With a window, in the background; `onChange` follows.
    func refresh() {
        refreshRequest += 1
        previewCancellation.cancel()
        let cancellation = CancellationFlag()
        previewCancellation = cancellation
        let cache = self.cache
        let (entries, settings, context, given, fileSystems) = (
            self.entries, self.settings, makeContext(cache: cache), givenNames, kernel.fileSystems
        )
        @Sendable func compute() -> RenamePreview {
            RenameComputation.preview(
                entries, settings: settings, context: context, given: given, fileSystems: fileSystems, cache: cache,
                cancellation: cancellation, isCancelled: { cancellation.isCancelled })
        }
        guard previewsInBackground else {
            apply(compute())
            return
        }
        isComputing = true
        queue.async { [weak self] in
            guard !cancellation.isCancelled else { return }
            let preview = autoreleasepool { compute() }
            let counts = preview.counts
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewCancellation === cancellation, !cancellation.isCancelled else { return }
                self.isComputing = false
                self.apply(preview, counts: counts)
            }
        }
    }

    private func apply(_ preview: RenamePreview, counts: RenamePreview.Counts? = nil) {
        guard preview.names.count == entries.count else { return }
        newNames = preview.names
        statuses = preview.statuses
        let counts = counts ?? preview.counts
        self.counts = (counts.changing, counts.conflicts, counts.errors)
        problem = preview.problem
        onChange?()
    }

    /// The new names as they stand, the old one where there is none.
    var targetNames: [String] { entries.indices.map { newNames[$0] ?? entries[$0].name } }

    /// The window was closed: the preview under way, and one waiting out the pause, are not wanted.
    func close() {
        previewCancellation.cancel()
        refreshRequest += 1
        isComputing = false
        onChange = nil
    }

    // MARK: The list

    /// The list changed. A cache is made again for the new list; with `keepingFolders` what
    /// was found out about the folders, and the dates in pictures, are taken along (the same
    /// items in another order, or fewer).
    private func listChanged(keepingFolders: Bool = false) {
        listGeneration += 1
        cache = keepingFolders ? cache.forChangedOrder() : RenameCache()
        onChange?()
        refresh()
    }

    /// Lists at least this long are worked on off the main thread.
    private static let backgroundSortThreshold = 2_000

    /// Sorts by a column; the order drives the counter `[C]`. The keys are worked out once
    /// per row, and a long list is sorted in the background (the list shows the new order
    /// when it is ready; a change of the list in the meantime drops the result, and of two
    /// sorts asked for in a row, the second wins).
    func sort(by key: SortKey, ascending: Bool) {
        guard !isBusy else { return }
        struct Keys {
            var name: Sorter.NameKey
            var ext: Sorter.NameKey
            var size: Int64
            var modified: Date
        }
        let rows = entries
        // Names from anywhere: by the kernel's keys, made once per row where the sort is
        // made (not Foundation's localized comparison, which is no order and ends the
        // program for some names).
        @Sendable func makeKeys() -> [Keys] {
            rows.map { entry -> Keys in
                let item = entry.item
                return Keys(
                    name: Sorter.key(of: entry.name, numeric: true),
                    ext: Sorter.key(
                        of: key == .ext && !item.isFolder ? FileItem.split(entry.name).ext : "", numeric: true),
                    size: item.size, modified: item.modified)
            }
        }
        @Sendable func inOrder(_ first: Keys, _ second: Keys) -> Bool {
            switch key {
            case .name: return first.name < second.name
            case .ext: return first.ext == second.ext ? first.name < second.name : first.ext < second.ext
            case .size: return first.size < second.size
            case .date: return first.modified < second.modified
            }
        }
        // A stable sort: equal items keep their order, also when the direction turns.
        @Sendable func permutation() -> [Int] {
            let keys = makeKeys()
            return keys.indices.sorted { first, second in
                if inOrder(keys[first], keys[second]) { return ascending }
                if inOrder(keys[second], keys[first]) { return !ascending }
                return first < second
            }
        }
        let apply: @MainActor @Sendable ([Int]) -> Void = { [self] order in
            reorder(order)
            dropGivenNames()
            listChanged(keepingFolders: true)
        }
        sortRequest += 1
        guard previewsInBackground, entries.count >= Self.backgroundSortThreshold else {
            apply(permutation())
            return
        }
        let (generation, request) = (listGeneration, sortRequest)
        isComputing = true
        sortQueue.async { [weak self] in
            let order = permutation()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listGeneration == generation, self.sortRequest == request else { return }
                apply(order)
            }
        }
    }

    /// Puts the rows in the order given by `order` (the old indexes, new row first).
    private func reorder(_ order: [Int]) {
        let (oldEntries, oldNames, oldStatuses) = (entries, newNames, statuses)
        entries = order.map { oldEntries[$0] }
        newNames = order.map { oldNames[$0] }
        statuses = order.map { oldStatuses[$0] }
    }

    /// Moves the rows one place up (-1) or down (+1) and returns where they are now.
    @discardableResult
    func move(_ indexes: IndexSet, by offset: Int) -> IndexSet {
        guard !isBusy, offset == 1 || offset == -1, let first = indexes.first, let last = indexes.last,
            offset < 0 ? first > 0 : last < entries.count - 1
        else { return indexes }
        for index in offset < 0 ? Array(indexes) : indexes.reversed() {
            entries.swapAt(index, index + offset)
            newNames.swapAt(index, index + offset)
            statuses.swapAt(index, index + offset)
        }
        listChanged(keepingFolders: true)
        return IndexSet(indexes.map { $0 + offset })
    }

    /// Moves rows in front of the row that is at `destination` now (drag and drop).
    @discardableResult
    func move(_ indexes: IndexSet, to destination: Int) -> IndexSet {
        guard !isBusy else { return indexes }
        let moved = indexes.filter(entries.indices.contains)
        guard !moved.isEmpty else { return [] }
        let insertion = destination - indexes.filter { $0 < destination }.count
        var order = entries.indices.filter { !indexes.contains($0) }
        order.insert(contentsOf: moved, at: min(max(insertion, 0), order.count))
        reorder(order)
        listChanged(keepingFolders: true)
        return IndexSet(integersIn: insertion..<(insertion + moved.count))
    }

    /// Takes rows out of the rename set.
    func remove(_ indexes: IndexSet) {
        guard !isBusy else { return }
        reorder(entries.indices.filter { !indexes.contains($0) })
        dropGivenNames()
        listChanged(keepingFolders: true)
    }

    /// "Next step" (F5): the computed names become the old names, so that another set of
    /// rules can be applied on top; the fields go back to "no change". Nothing is renamed yet.
    func nextStep() {
        guard !isBusy else { return }
        let (oldEntries, names) = (entries, newNames)
        @Sendable func renamed() -> [RenameEntry] {
            var entries = oldEntries
            for index in entries.indices {
                if let name = names[index], RenameEngine.invalidity(of: name) == nil { entries[index].name = name }
            }
            return entries
        }
        let finish: @MainActor @Sendable ([RenameEntry]) -> Void = { [self] updated in
            entries = updated
            givenNamesStorage = nil
            // The subjects carry the old names.
            listGeneration += 1
            cache = cache.forChangedOrder()
            if settings == .unchanged { listChanged(keepingFolders: true) } else { settings = .unchanged }
            onChange?()
        }
        guard previewsInBackground, oldEntries.count >= Self.backgroundSortThreshold else {
            finish(renamed())
            return
        }
        let generation = listGeneration
        isComputing = true
        sortQueue.async { [weak self] in
            let updated = renamed()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listGeneration == generation else { return }
                finish(updated)
            }
        }
    }

    // MARK: Names from a list

    /// A given name belongs to a place in the list; a list in another order has none.
    private func dropGivenNames() {
        givenNamesStorage = nil
    }

    /// Takes the new names from a text, one per line, in list order.
    func loadNames(fromText text: String) {
        guard !isBusy else { return }
        applyGivenNames(RenameNameList.names(in: text))
    }

    private func applyGivenNames(_ names: [String]) {
        givenNamesStorage = names.isEmpty ? nil : names
        listChanged(keepingFolders: true)
    }

    /// Reads a list of names from a file on any file system, off the main thread; the text is
    /// split into lines there too.
    func loadNames(from url: URL, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !isBusy else { return }
        let fileSystems = kernel.fileSystems
        @Sendable func read() -> Result<[String], any Error> {
            Result {
                let reader = try fileSystems.provider(for: url).read(url)
                defer { reader.close() }
                var data = Data()
                // A list of names is small; what is beyond 32 MB is not one.
                while data.count < 32 << 20, let block = try reader.read(upToCount: 1 << 20) { data.append(block) }
                return RenameNameList.names(in: RenameNameList.text(from: data))
            }
        }
        let finish: @MainActor @Sendable (Result<[String], any Error>) -> Void = { [self] result in
            switch result {
            case .success(let names): applyGivenNames(names)
            case .failure(let error): kernel.ui.report(error, title: "The names cannot be loaded!")
            }
            completion?()
        }
        guard previewsInBackground else {
            finish(read())
            return
        }
        // (The file may lie on a server: on a thread of the kernel's own.)
        BlockingCalls.run {
            let result = autoreleasepool { read() }
            performOnMainLoop { finish(result) }
        }
    }

    /// "Edit names": the new names as text, one per line, for the user to change.
    func editNames() {
        guard !isBusy else { return }
        let ask: @MainActor @Sendable (String) -> Void = { [self] text in
            let fields = [FormField.lines("names", "", text)]
            guard
                let answer = kernel.ui.form(
                    "Edit names", detail: "One name per line, in the order of the list.", fields: fields,
                    buttons: ["OK"])
            else {
                return
            }
            loadNames(fromText: answer.text("names"))
        }
        // The text of a long list is put together in the background.
        guard previewsInBackground, entries.count >= Self.backgroundSortThreshold else {
            ask(targetNames.joined(separator: "\n"))
            return
        }
        let (current, names, generation) = (entries, newNames, listGeneration)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = current.indices.map { names[$0] ?? current[$0].name }.joined(separator: "\n")
            performOnMainLoop { [weak self] in
                guard let self, self.listGeneration == generation else { return }
                ask(text)
            }
        }
    }

    /// Back to names made by the masks.
    func clearGivenNames() {
        guard !isBusy else { return }
        givenNamesStorage = nil
        listChanged(keepingFolders: true)
    }

    // MARK: Saved settings

    func save(as name: String) {
        let name = String(name.trimmingCharacters(in: .whitespaces).prefix(252))
        guard !name.isEmpty else { return }
        store.saved[name] = settings
        onChange?()
    }

    /// False when there are no settings of that name.
    @discardableResult
    func load(_ name: String) -> Bool {
        guard let saved = store.saved[name] else { return false }
        settings = saved
        return true
    }

    func deleteSaved(_ name: String) {
        store.saved[name] = nil
        onChange?()
    }

    /// Puts what is in the fields at the top of their histories; done when a run starts.
    private func rememberFields() {
        store.remember(settings.nameMask, in: .nameMask)
        store.remember(settings.search, in: .search)
        store.remember(settings.replacement, in: .replacement)
    }

    // MARK: Start!

    private enum ConflictChoice {
        case autoRename, skip, cancel
    }

    /// What a run did, with everything the main thread needs worked out in the job.
    private struct Outcome {
        var result = RenameRunResult()
        /// The entries the result's item numbers refer to.
        var entries: [RenameEntry] = []
        var unusable = 0
        /// The folders to read again.
        var folders: [URL] = []
        /// For each entry: whether it was renamed and so leaves the list.
        var renamed: [Bool] = []
    }

    var logURL: URL { logDirectory.appendingPathComponent(RenameLog.fileName) }
    var canUndo: Bool { !isBusy && store.undoLimit > 0 && store.undoCount > 0 }
    var hasResultList: Bool { !lastRun.isEmpty }

    /// Renames the items in list order, as a job with progress. The names are computed afresh
    /// on the job's thread, so what happens is what the fields say, whatever the preview
    /// has caught up with; the job ends when it is cancelled, also in the middle of a regular
    /// expression. `completion` runs on the main thread.
    func start(completion: (@MainActor (RenameRunResult) -> Void)? = nil) {
        guard !entries.isEmpty, !isBusy else { return }
        rememberFields()
        isBusy = true
        // A sort or "next step" still under way would change the list the run is about to use.
        listGeneration += 1
        // A run looks at the folders afresh: nothing is taken from the previews' cache.
        let fresh = RenameCache()
        titleRule = store.titleRule
        let (entries, settings, context, given) = (self.entries, self.settings, makeContext(cache: fresh), givenNames)
        let (fileSystems, ui, logURL) = (kernel.fileSystems, kernel.ui, self.logURL)
        kernel.jobs.run(
            title: "Multi-Rename:",
            work: { monitor -> Outcome in
                let preview = RenameComputation.preview(
                    entries, settings: settings, context: context, given: given, fileSystems: fileSystems,
                    cache: fresh, cancellation: monitor.cancellation, isCancelled: { monitor.cancellation.isCancelled }
                )
                var outcome = Outcome(entries: entries)
                outcome.unusable = preview.statuses.filter { $0 == .error || $0.isInvalid }.count
                guard !monitor.cancellation.isCancelled else {
                    outcome.result.cancelled = true
                    return outcome
                }
                // Names that come from a file or were typed can lead anywhere: a name with a slash
                // moves the file into that folder, a name that starts with one anywhere on the disk.
                if given != nil {
                    let moving = preview.names.indices.filter {
                        preview.statuses[$0] == .ready && preview.names[$0]?.utf8.contains(0x2F) == true
                    }
                    if !moving.isEmpty {
                        let examples =
                            moving.prefix(8).map { (preview.names[$0] ?? "") }.joined(separator: "\n")
                            + (moving.count > 8 ? "\n…" : "")
                        let go = monitor.ask { @MainActor @Sendable in
                            ui.choose(
                                "\(moving.count) of the names given move the file into another folder.",
                                detail: examples
                                    + "\n\nA name with a / puts the file in that folder, and one that starts with a / anywhere on the disk. Rename anyway?",
                                buttons: ["Rename", "Cancel"], style: .warning) == 0
                        }
                        guard go else {
                            outcome.result.cancelled = true
                            return outcome
                        }
                    }
                }
                let sources = entries.map(\.item.url)
                var targets = preview.targets
                let conflicts = preview.conflicts
                if !conflicts.isEmpty {
                    let names =
                        conflicts.prefix(12).map { preview.names[$0] ?? "" }.joined(separator: "\n")
                        + (conflicts.count > 12 ? "\n…" : "")
                    let choice = monitor.ask { @MainActor @Sendable in
                        ui.pick(
                            "Name conflict: \(conflicts.count) file(s) would get a name that is already in use.",
                            detail: names + "\n\nAuto-rename them to \"name (2).ext\", \"name (3).ext\", …?",
                            [("Auto-rename", .autoRename), ("Skip these files", .skip), ("Cancel", .cancel)],
                            fallback: ConflictChoice.cancel)
                    }
                    switch choice {
                    case .cancel:
                        outcome.result.cancelled = true
                        return outcome

                    case .autoRename:
                        targets = preview.planner.autoRenamed(
                            sources: sources, targets: targets, isFolder: entries.map(\.item.isFolder),
                            existing: preview.existing)

                    case .skip:
                        // Leaving an item where it is can put it in the way of another one.
                        targets = preview.planner.skippingConflicts(
                            sources: sources, targets: targets, existing: preview.existing)
                    }
                }
                let steps = preview.planner.steps(
                    sources: sources, targets: targets, isFolder: entries.map(\.item.isFolder),
                    cancelled: { monitor.cancellation.isCancelled })
                guard !monitor.cancellation.isCancelled else {
                    outcome.result.cancelled = true
                    return outcome
                }
                let total = Set(steps.map(\.item)).count
                let runner = RenameRunner(fileSystems: fileSystems, cancellation: monitor.cancellation)
                var lastReport = Date.distantPast
                runner.onProgress = { step, done in
                    // A list of a hundred thousand files must not flood the progress window.
                    guard Date().timeIntervalSince(lastReport) > 0.05 else { return }
                    lastReport = Date()
                    monitor.report(
                        JobProgress(
                            lines: [
                                "From: " + fileSystems.displayPath(sources[step.item]),
                                "To: " + step.to.lastPathComponent
                            ],
                            itemsDone: done, itemsTotal: total))
                }
                outcome.result = runner.run(steps, sources: sources)
                // What the main thread will need, so that it does not walk the list for it.
                let from = Set(outcome.result.renamed.map { $0.from.locationKey })
                outcome.renamed =
                    from.isEmpty
                    ? []
                    : Parallel.map(entries, serialBelow: RenameComputation.parallelThreshold) {
                        from.contains($0.item.url.locationKey)
                    }
                var folders = Set<String>()
                outcome.folders = outcome.result.renamed.flatMap {
                    [$0.from.deletingLastPathComponent(), $0.to.deletingLastPathComponent()]
                }
                .filter { folders.insert($0.locationKey).inserted }
                if !outcome.result.renamed.isEmpty {
                    RenameLog.write(outcome.result.renamed, to: logURL, fileSystems: fileSystems)
                }
                return outcome
            },
            completion: { outcome in
                // The session lives until its job has ended, also when the window was closed meanwhile.
                self.isBusy = false
                self.finish(outcome)
                completion?(outcome.result)
            })
    }

    /// A successful run shows no message: the renamed items leave the list and Undo and the
    /// result list become available. What failed stays in the list and is reported.
    private func finish(_ outcome: Outcome) {
        let result = outcome.result
        if !result.renamed.isEmpty {
            lastRun = result.renamed
            store.appendUndo(result.renamed)
            // The list could not change meanwhile, so the flags of the run are the list's own.
            if outcome.renamed.count == entries.count {
                reorder(entries.indices.filter { !outcome.renamed[$0] })
            } else {
                let gone = Set(result.renamed.map(\.from.locationKey))
                reorder(entries.indices.filter { !gone.contains(entries[$0].item.url.locationKey) })
            }
            givenNamesStorage = nil
            kernel.panels.refresh(outcome.folders, focus: result.renamed.last?.to)
        }
        if !result.failures.isEmpty {
            let lines = result.failures.prefix(15).map { failure in
                (outcome.entries.indices.contains(failure.item) ? outcome.entries[failure.item].item.name : "?") + ": "
                    + failure.message
            }
            kernel.ui.inform(
                "\(result.failures.count) file(s) could not be renamed!",
                detail: lines.joined(separator: "\n") + (result.failures.count > 15 ? "\n…" : ""), style: .warning)
        } else if outcome.unusable > 0, !result.cancelled {
            kernel.ui.inform(
                "\(outcome.unusable) file(s) were left out because the rename mask gives no valid name for them.",
                detail: "", style: .warning)
        }
        listChanged()
    }

    // MARK: Undo and result list

    private struct UndoOutcome {
        var result = RenameRunResult()
        /// What was asked for and not put back.
        var attempted: [RenamedItem] = []
        /// Of these, what is still to be undone later.
        var left: [RenamedItem] = []
        var folders: [URL] = []
    }

    /// Undoes the last run after asking, last renamed first. `completion` runs on the main
    /// thread with what could not be put back; it is not called when the user says no.
    func undo(completion: (@MainActor ([RenamedItem]) -> Void)? = nil) {
        guard canUndo else { return }
        // Pressed again while this one is under way, it would find the same run and undo it twice.
        isBusy = true
        listGeneration += 1
        guard previewsInBackground else {
            performUndo(completion: completion)
            return
        }
        store.loadUndo { [weak self] in self?.performUndo(completion: completion) }
    }

    private func performUndo(completion: (@MainActor ([RenamedItem]) -> Void)?) {
        guard let last = store.lastUndo else {
            isBusy = false
            return
        }
        let lines = last.prefix(20).map { "\($0.from.lastPathComponent) -> \($0.to.lastPathComponent)" }
        let detail =
            "Undo the following rename action:\n" + lines.joined(separator: "\n")
            + (last.count > 20 ? "\n… (\(last.count) files)" : "")
        guard kernel.ui.choose(kernel.productName, detail: detail, buttons: ["Yes", "No"], style: .information) == 0
        else {
            isBusy = false
            return
        }
        let fileSystems = kernel.fileSystems
        let back = Array(last.reversed())
        let runs = store.undoCount
        kernel.jobs.run(
            title: "Undo rename:",
            work: { monitor -> UndoOutcome in
                let (sources, targets) = (back.map(\.to), back.map { Optional($0.from) })
                let survey = RenameSurvey(fileSystems: fileSystems, cancellation: monitor.cancellation)
                let planner = RenamePlanner(
                    foldsCase: survey.foldsCase(sources.prefix(16).compactMap(fileSystems.item(at:))))
                let runner = RenameRunner(fileSystems: fileSystems, cancellation: monitor.cancellation)
                var lastReport = Date.distantPast
                runner.onProgress = { step, done in
                    guard Date().timeIntervalSince(lastReport) > 0.05 else { return }
                    lastReport = Date()
                    monitor.report(
                        JobProgress(
                            lines: ["From: " + fileSystems.displayPath(step.from), "To: " + step.to.lastPathComponent],
                            itemsDone: done, itemsTotal: back.count))
                }
                var outcome = UndoOutcome()
                let steps = planner.steps(
                    sources: sources, targets: targets, cancelled: { monitor.cancellation.isCancelled })
                guard !monitor.cancellation.isCancelled else {
                    outcome.result.cancelled = true
                    return outcome
                }
                outcome.result = runner.run(steps, sources: sources)
                // What was not put back is kept for another try, unless the file it was to be
                // taken from is gone: that can never be undone and must not hold up earlier runs.
                let restored = Set(outcome.result.renamed.map(\.from.locationKey))
                outcome.attempted = last.filter { !restored.contains($0.to.locationKey) }
                let present = Parallel.map(outcome.attempted) { fileSystems.item(at: $0.to) != nil }
                let stillThere = Set(zip(outcome.attempted, present).filter(\.1).map(\.0.to.locationKey))
                outcome.left = outcome.attempted.filter { stillThere.contains($0.to.locationKey) }
                var folders = Set<String>()
                outcome.folders = last.flatMap {
                    [$0.from.deletingLastPathComponent(), $0.to.deletingLastPathComponent()]
                }
                .filter { folders.insert($0.locationKey).inserted }
                return outcome
            },
            completion: { outcome in
                self.isBusy = false
                // Only the run that was asked about is replaced.
                if self.store.undoCount == runs { self.store.replaceLastUndo(with: outcome.left) }
                self.lastRun = []
                self.kernel.panels.refresh(outcome.folders, focus: outcome.result.renamed.last?.to)
                if !outcome.left.isEmpty {
                    self.kernel.ui.inform(
                        "\(outcome.attempted.count) file(s) could not be renamed back!",
                        detail: outcome.result.failures.prefix(15).map(\.message).joined(separator: "\n"),
                        style: .warning)
                }
                self.cache = RenameCache()
                self.listGeneration += 1
                self.onChange?()
                // The files are where they were: the marks of conflicts in the list are looked at again.
                self.refresh()
                completion?(outcome.attempted)
            })
    }

    /// Shows the log of the last run in the viewer.
    func showResultList() {
        guard hasResultList else { return }
        if let viewer = kernel.services.find((any ViewerService).self) {
            viewer.view(logURL)
        } else if kernel.commands[.view] != nil {
            kernel.commands.perform(.view, .location(logURL))
        } else {
            _ = kernel.ui.form(
                "Result list", detail: "",
                fields: [.lines("log", "", RenameLog.text(lastRun, fileSystems: kernel.fileSystems))],
                buttons: ["Close"])
        }
    }
}

extension RenameStatus {
    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

/// `[T4]`: the date a camera recorded in a picture (EXIF "date taken", else the digitized or
/// the plain date; spec 18 › Date and time). Read from files on the local disk only; called
/// on the preview threads. Only plain files of a picture type that are on this disk are opened:
/// a FIFO in the list would hold a preview thread for good, a stub of a file in the cloud would
/// be downloaded, and the decoders of ImageIO are not pointed at what is not a picture.
enum ContentDate {
    static func read(_ url: URL) -> Date? {
        guard url.isFileURL, isPicture(url), isPlainFileHere(url),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text =
            exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]
            ?? tiff?[kCGImagePropertyTIFFDateTime]
        guard let text = text as? String else { return nil }
        return formatter.date(from: text)
    }

    /// Whether the name is that of a picture (or a camera's raw file).
    static func isPicture(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .rawImage)
    }

    /// A regular file whose contents are on this disk.
    static func isPlainFileHere(_ url: URL) -> Bool {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in path.map { stat($0, &info) } ?? -1 }
        // SF_DATALESS: the contents are in the cloud.
        return result == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_flags & 0x4000_0000 == 0
    }

    /// One formatter for all files; formatting and parsing with it is safe from several threads.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

/// Hands a block to the main thread through the run loop (all modes that count), not through the
/// main dispatch queue: a block that asks the user something runs a modal dialog, and a dialog
/// started from inside a block of the main queue keeps every later block of the queue waiting.
func performOnMainLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    // The main run loop runs its blocks on the main thread.
    RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
