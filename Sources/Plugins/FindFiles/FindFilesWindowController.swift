import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// Find Files (spec 09 › Find Files): the form in four tabs on top, the result list below.
///
/// **Threading.** The window and everything it holds belong to the main thread. A search runs
/// on a background queue (`FileSearch`, which spreads the reading of files over all cores) and
/// hands its hits to the main thread in batches (by count and by time, so that a folder with a
/// million hits arrives in pieces); a batch of a search that is no longer the current one is
/// dropped. Spotlight is asked from the main thread, as the system requires; its answer is read
/// and checked in the background. What the end of a search or an action on the results would
/// otherwise do to every row (counting, building the text to copy, making the list of
/// locations) is kept up to date as rows arrive or done in the background.
final class FindFilesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    /// A line of the result list (spec 09 › Running a search and the result list).
    enum Row {
        /// `[6 files and 0 directories found]`, always the first line.
        case summary(String)
        case item(FileItem)
        /// The dashed line between two groups of duplicates.
        case separator
    }

    /// What one search found; kept so `<` and `>` can step through the earlier ones.
    private struct ResultSet {
        var rows: [Row]
        var showsDuplicates: Bool
        var urls: [URL]
        var files: Int
        var directories: Int
    }

    /// A finished result list made off the main thread: the rows (the summary first, to be
    /// filled in), the locations of the items in them, and the counts.
    private struct Built {
        var rows: [Row]
        var urls: [URL]
        var files: Int
        var directories: Int
        var showsDuplicates: Bool

        static func make(items: [FileItem]) -> Self {
            var rows: [Row] = [.summary("")]
            rows.reserveCapacity(items.count + 1)
            var directories = 0
            for item in items {
                rows.append(.item(item))
                if item.isDirectory { directories += 1 }
            }
            return Self(
                rows: rows, urls: items.map(\.url), files: items.count - directories, directories: directories,
                showsDuplicates: false)
        }

        static func make(groups: [[FileItem]]) -> Self {
            var built = make(items: [])
            for (index, group) in groups.enumerated() {
                if index > 0 { built.rows.append(.separator) }
                for item in group {
                    built.rows.append(.item(item))
                    built.urls.append(item.url)
                    if item.isDirectory { built.directories += 1 } else { built.files += 1 }
                }
            }
            built.showsDuplicates = true
            return built
        }
    }

    static let keepResultsKey = "findFiles.keepResults"
    static let historyLengthKey = "findFiles.historyLength"
    static let spotlightKey = "findFiles.spotlight"
    static let historyLengths = [10, 20, 50, 100]
    /// The most hits a search of the window lists; it stops there and says so.
    static let resultLimit = 2_000_000
    /// The most rows handed to the list in one piece.
    private static let batchSize = 2_000
    /// Lists up to this many rows are worked on the main thread where that is simpler.
    private static let smallList = 20_000

    private final class ResultsTableView: NSTableView {
        var onKey: ((NSEvent) -> Bool)?

        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }

    /// F2 belongs to "Search in found files" wherever the keyboard is in the window.
    private final class FindWindow: ToolWindow {
        var onF2: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown, Shortcut.f(2).matches(event) {
                onF2?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    let form: SearchForm
    /// Called when the window was closed.
    var onClose: (FindFilesWindowController) -> Void = { _ in }
    /// Called when a search has ended, also a cancelled one.
    var onFinished: () -> Void = {}

    private let startButton = NSButton(title: "Start search", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Close", target: nil, action: nil)
    private let backButton = NSButton(title: "<", target: nil, action: nil)
    private let forwardButton = NSButton(title: ">", target: nil, action: nil)
    private let inFoundBox = NSButton(checkboxWithTitle: "F2 Search in found files/folders", target: nil, action: nil)
    private let resultsTable = ResultsTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var resultButtons: [NSButton] = []
    private var feedButton = NSButton()
    private var newSearchButton = NSButton()

    private let kernel: Kernel
    private let store: SearchStore
    private var includeHidden = false
    private var startDirectory = URL(fileURLWithPath: "/")
    private var rows: [Row] = []
    /// The locations of the items in `rows`, in list order; kept as rows arrive so that nothing
    /// needs to walk the list for them.
    private var resultURLs: [URL] = []
    private var foundFiles = 0
    private var foundDirectories = 0
    /// Counts the requests to copy the list, so that an older one is dropped.
    private var copyRequest = 0
    private var showsDuplicates = false
    private var earlier: [ResultSet] = []
    private static let earlierLimit = 10
    private static let earlierRowLimit = 200_000
    private var earlierIndex = 0
    private var search: FileSearch?
    private var spotlight: SpotlightSearch?

    init(kernel: Kernel, title: String = "Find Files") {
        self.kernel = kernel
        store = SearchStore(settings: kernel.settings)
        form = SearchForm(
            fields: SearchField.all(fileSystems: kernel.fileSystems, columns: kernel.columns), store: store,
            ui: kernel.ui)
        let window = FindWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 520)
        window.center()
        super.init(window: window)
        window.delegate = self
        // Esc interrupts a running search; when idle it closes the window.
        window.onEscape = { [weak self] in
            guard let self, isSearching else { return false }
            cancelSearch()
            return true
        }
        window.onF2 = { [weak self] in
            guard let self, inFoundBox.isEnabled else { return }
            inFoundBox.state = inFoundBox.state == .on ? .off : .on
        }
        form.onSubmit = { [weak self] in
            if self?.isSearching == false { self?.startSearch() }
        }
        var initial = SearchSettings()
        initial.useSpotlight = kernel.settings.flag(Self.spotlightKey, default: false)
        form.settings = initial
        buildContent(in: window)
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    /// Shows the window with "Search in" set to `directory`. Results are viewed, edited and
    /// shown in the panel through the kernel's commands.
    func show(startingIn directory: URL, includeHidden: Bool) {
        prepare(startingIn: directory, includeHidden: includeHidden)
        showWindow(nil)
        window?.makeFirstResponder(form.searchForField)
    }

    /// Everything `show` does except putting the window on screen. The names and the text
    /// stay from last time; the Advanced tab starts empty (spec 09 › What is remembered).
    func prepare(startingIn directory: URL, includeHidden: Bool) {
        self.includeHidden = includeHidden
        startDirectory = directory
        var settings = form.settings
        settings.searchIn = kernel.fileSystems.displayPath(directory)
        settings.criteria = FileCriteria()
        settings.duplicates = DuplicateOptions()
        settings.onlySelected = false
        form.settings = settings
        form.setSelectionAvailable(hasSelectedItems)
        form.tabView.selectTabViewItem(at: 0)
        if !isSearching, !kernel.settings.flag(Self.keepResultsKey, default: true) {
            clearResults()
        }
    }

    /// Whether anything is marked in the source panel; asked often, so it does not look at the items.
    private var hasSelectedItems: Bool { kernel.panels.source.model.selectionCount > 0 }

    /// The marked items of the source panel, for "Only search in selected directories/files".
    private var selectedItems: [URL] {
        let model = kernel.panels.source.model
        return model.items.filter { model.isSelected($0) }.map(\.url)
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        startButton.target = self
        startButton.action = #selector(startPressed)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        for (button, action) in [(backButton, #selector(showEarlier)), (forwardButton, #selector(showLater))] {
            button.target = self
            button.action = action
            button.bezelStyle = .roundRect
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = "Search results"
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.rowHeight = 18
        resultsTable.style = .plain
        resultsTable.usesAlternatingRowBackgroundColors = true
        resultsTable.target = self
        resultsTable.doubleAction = #selector(goToFile)
        resultsTable.onKey = { [weak self] event in self?.handleResultKey(event) ?? false }
        let scroll = NSScrollView()
        scroll.documentView = resultsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newSearchButton = NSButton(title: "New search", target: self, action: #selector(newSearch))
        feedButton = NSButton(title: "Feed to listbox", target: self, action: #selector(feedToListbox))
        resultButtons = [
            NSButton(title: "F3 View", target: self, action: #selector(viewResult)),
            NSButton(title: "F4 Edit", target: self, action: #selector(editResult)),
            NSButton(title: "Go to file", target: self, action: #selector(goToFile))
        ]

        let buttons = NSStackView(views: [startButton, cancelButton])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 8
        buttons.edgeInsets.top = 24
        for button in [startButton, cancelButton] {
            button.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        let top = NSStackView(views: [form.tabView, buttons])
        top.alignment = .top
        form.tabView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [
            NSTextField(labelWithString: "Search results:"), NSView(), backButton, forwardButton, inFoundBox
        ])
        let footer = NSStackView(views: [
            resultButtons[0], resultButtons[1], newSearchButton, resultButtons[2], feedButton, NSView()
        ])
        let stack = NSStackView(views: [top, header, scroll, footer, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        for part in [top, header, scroll, footer, statusLabel] as [NSView] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        window.contentView = stack
        updateButtons()
    }

    private func updateButtons() {
        cancelButton.title = isSearching ? "Cancel" : "Close"
        startButton.isEnabled = !isSearching
        let hasResult = selectedResult != nil
        resultButtons.forEach { $0.isEnabled = hasResult }
        let hasItems = !isSearching && foundFiles + foundDirectories > 0
        feedButton.isEnabled = hasItems && kernel.services.find((any FileListService).self) != nil
        newSearchButton.isEnabled = !isSearching && !rows.isEmpty
        inFoundBox.isEnabled = hasItems
        if !hasItems { inFoundBox.state = .off }
        backButton.isEnabled = !isSearching && earlierIndex > 0
        forwardButton.isEnabled = !isSearching && earlierIndex < earlier.count - 1
    }

    // MARK: Searching

    var isSearching: Bool { search != nil }

    @objc private func startPressed() {
        if !isSearching { startSearch() }
    }

    @objc private func cancelPressed() {
        if isSearching { cancelSearch() } else { close() }
    }

    /// Stops the running search if it looks through `volume` (which is about to be ejected).
    func cancelSearch(ifItReads volume: URL) {
        guard isSearching else { return }
        let places = form.settings.searchIn.split(separator: ";")
            .map {
                kernel.fileSystems.location(
                    from: String($0).trimmingCharacters(in: .whitespaces), relativeTo: startDirectory)
            }
        // A search whose places are not known is stopped too: better a search again than a drive refused.
        if places.isEmpty
            || places.contains(where: { $0.isFileURL && ($0.isSameLocation(as: volume) || $0.isInside(volume)) })
        {
            cancelSearch()
        }
    }

    /// Stops the running search; it ends through the usual path with what it has.
    func cancelSearch() {
        search?.cancel()
        if let spotlight {
            spotlight.stop()
            self.spotlight = nil
            finish(built: Built.make(items: []))
        }
    }

    /// Starts the search the form describes. A form that cannot be searched with (a broken
    /// regular expression) is reported instead.
    func startSearch() {
        let settings = form.settings
        // Start directories the user typed (not the ones the window was opened with or a saved
        // search brought) are the user's own choice of their servers, if they name any.
        if settings.searchIn != form.placedSearchIn {
            for part in settings.searchIn.split(separator: ";") {
                kernel.userTyped(location: String(part), relativeTo: startDirectory)
            }
        }
        var query = settings.query(
            relativeTo: startDirectory, fileSystems: kernel.fileSystems, includeHidden: includeHidden,
            selected: settings.onlySelected ? selectedItems : [])
        if inFoundBox.state == .on { query.onlyItems = resultURLs }
        query.resultLimit = Self.resultLimit
        let search = FileSearch(query, fileSystems: kernel.fileSystems, columns: kernel.columns)
        if let problem = search.problem {
            kernel.ui.report(problem, title: "The search cannot start")
            return
        }
        form.rememberHistory(
            limit: Self.historyLengths[
                min(
                    max(kernel.settings.index(Self.historyLengthKey, default: 1), 0),
                    Self.historyLengths.count - 1)])
        self.search = search
        rows = [.summary("[Searching...]")]
        (resultURLs, foundFiles, foundDirectories) = ([], 0, 0)
        showsDuplicates = false
        resultsTable.reloadData()
        statusLabel.stringValue = "[Searching...]"
        updateButtons()

        if settings.useSpotlight, SpotlightQuery.isAvailable(for: query),
            let spotlight = SpotlightSearch(SpotlightQuery.string(for: query), scopes: query.directories)
        {
            askSpotlight(spotlight, for: search)
        } else if query.duplicates.isActive {
            walkForDuplicates(search)
        } else {
            walk(search)
        }
    }

    private func walk(_ search: FileSearch) {
        // On a thread of the kernel's own, like everything here that waits for a file
        // system: a search on a share that has stopped answering keeps its thread, and the
        // system's shared pool has none to spare for that.
        BlockingCalls.run { [weak self] in
            // Hits and the folder being searched are handed over in batches, by count and by
            // time, so a large search does not flood the window and a folder with a million
            // hits does not arrive in one piece. These variables belong to the search thread.
            var pending: [FileItem] = []
            var lastFlush = Date()
            func flush(_ directory: URL?) {
                let batch = pending
                pending = []
                lastFlush = Date()
                DispatchQueue.main.async {
                    guard let self, self.search === search else { return }
                    self.append(batch)
                    if let directory { self.statusLabel.stringValue = self.kernel.fileSystems.displayPath(directory) }
                }
            }
            search.run(
                onDirectory: { directory in
                    if Date().timeIntervalSince(lastFlush) > 0.1 { flush(directory) }
                },
                onMatch: { item in
                    pending.append(item)
                    if pending.count >= Self.batchSize
                        || (pending.count % 128 == 0 && Date().timeIntervalSince(lastFlush) > 0.1)
                    {
                        flush(nil)
                    }
                })
            flush(nil)
            DispatchQueue.main.async {
                guard let self, self.search === search else { return }
                self.finish(built: nil, notes: self.notes(of: search))
            }
        }
    }

    /// What the summary has to add about a search that did not go as asked.
    private func notes(of search: FileSearch) -> [String] {
        var notes: [String] = []
        if search.reachedResultLimit { notes.append("stopped at \(Self.resultLimit) results") }
        if search.regexTimedOut { notes.append("a regular expression was too slow for some names") }
        return notes
    }

    /// Duplicates are only known when everything has been found and compared, so nothing is
    /// listed before the end; the status line tells how far the work is.
    private func walkForDuplicates(_ search: FileSearch) {
        let fileSystems = kernel.fileSystems
        BlockingCalls.run { [weak self] in
            var lastReport = Date.distantPast
            func status(_ text: @autoclosure () -> String) {
                guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
                lastReport = Date()
                let text = text()
                DispatchQueue.main.async {
                    guard let self, self.search === search else { return }
                    self.statusLabel.stringValue = text
                }
            }
            let groups = search.runForDuplicates(
                onDirectory: { directory in status(fileSystems.displayPath(directory)) },
                onHashing: { done, total in status("Comparing contents: \(done) of \(total)") })
            let built = Built.make(groups: groups)
            DispatchQueue.main.async {
                guard let self, self.search === search else { return }
                self.finish(built: built, notes: self.notes(of: search))
            }
        }
    }

    private func askSpotlight(_ spotlight: SpotlightSearch, for search: FileSearch) {
        self.spotlight = spotlight
        statusLabel.stringValue = "[Asking Spotlight...]"
        let fileSystems = kernel.fileSystems
        spotlight.start { [weak self] paths, truncated in
            guard let self, self.search === search else { return }
            self.spotlight = nil
            statusLabel.stringValue = "[Checking \(paths.count) files...]"
            BlockingCalls.run { [weak self] in
                let items = SpotlightQuery.verify(paths, with: search, fileSystems: fileSystems)
                let groups =
                    search.query.duplicates.isActive
                    ? DuplicateFinder.groups(
                        of: items, options: search.query.duplicates, fileSystems: fileSystems,
                        cancellation: search.cancellation)
                    : nil
                let built = groups.map(Built.make(groups:)) ?? Built.make(items: items)
                DispatchQueue.main.async {
                    guard let self, self.search === search else { return }
                    var notes = self.notes(of: search)
                    if truncated {
                        notes.append(
                            "Spotlight gave more than \(SpotlightSearch.resultLimit) files, the rest were left out")
                    }
                    self.finish(built: built, notes: notes)
                }
            }
        }
    }

    private func append(_ batch: [FileItem]) {
        guard !batch.isEmpty else { return }
        let first = rows.count
        rows.reserveCapacity(first + batch.count)
        for item in batch {
            rows.append(.item(item))
            resultURLs.append(item.url)
            if item.isDirectory { foundDirectories += 1 } else { foundFiles += 1 }
        }
        resultsTable.insertRows(at: IndexSet(integersIn: first..<rows.count))
    }

    /// Ends the search. `built` replaces what was listed while it ran (Spotlight's answer,
    /// duplicates in groups); without it the rows that arrived are kept and only the summary
    /// line is filled in. `notes` say what did not go as asked.
    private func finish(built: Built?, notes: [String] = []) {
        let wasCancelled = search?.cancellation.isCancelled ?? false
        search = nil
        if let built {
            (rows, resultURLs, foundFiles, foundDirectories, showsDuplicates) = (
                built.rows, built.urls, built.files, built.directories, built.showsDuplicates
            )
        }
        if rows.isEmpty { rows = [.summary("")] }
        let found = foundFiles + foundDirectories
        let counts = "\(foundFiles) files and \(foundDirectories) directories"
        var summary =
            wasCancelled
            ? (found == 0 ? "[Search cancelled]" : "[Search cancelled, \(counts) found so far]")
            : found == 0 ? "[No files found]" : "[\(counts) found]"
        if !notes.isEmpty {
            summary =
                String(summary.dropLast(summary.hasSuffix("]") ? 1 : 0)) + " - " + notes.joined(separator: "; ") + "]"
        }
        rows[0] = .summary(summary)
        if built != nil {
            resultsTable.reloadData()
        } else {
            resultsTable.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
        }
        statusLabel.stringValue = summary
        earlier.append(
            ResultSet(
                rows: rows, showsDuplicates: showsDuplicates, urls: resultURLs, files: foundFiles,
                directories: foundDirectories))
        // The last few searches are kept, as far as their lists are not huge.
        var kept = 0
        for (index, set) in earlier.enumerated().reversed() {
            kept += set.rows.count
            if index < earlier.count - Self.earlierLimit
                || (kept > Self.earlierRowLimit && index < earlier.count - 1)
            {
                let dropped = Array(earlier[...index])
                earlier.removeFirst(index + 1)
                // Freeing a list of millions of rows is not done on the main thread.
                DispatchQueue.global(qos: .utility).async { withExtendedLifetime(dropped) {} }
                break
            }
        }
        earlierIndex = earlier.count - 1
        if found > 0 {
            resultsTable.selectRowIndexes([1], byExtendingSelection: false)
            window?.makeFirstResponder(resultsTable)
        }
        updateButtons()
        onFinished()
    }

    // MARK: Results

    /// The files and folders in the list, in list order.
    var resultItems: [FileItem] {
        rows.compactMap { row in
            if case .item(let item) = row { return item }
            return nil
        }
    }

    /// The lines of the list as they are shown and copied.
    var lines: [String] { rows.map(text) }

    private func text(of row: Row) -> String {
        switch row {
        case .summary(let text): return text
        case .separator: return String(repeating: "- ", count: 40)

        case .item(let item):
            return Self.text(
                of: item, showsDuplicates: showsDuplicates, fileSystems: kernel.fileSystems)
        }
    }

    private static func text(of item: FileItem, showsDuplicates: Bool, fileSystems: FileSystemRegistry) -> String {
        guard showsDuplicates else { return fileSystems.displayPath(item.url) }
        // Duplicates read `name  -  folder/` (spec 09 › Duplicate finder, Output).
        let folder = fileSystems.displayPath(item.url.deletingLastPathComponent())
        return "\(item.name)  -  \(folder.hasSuffix("/") ? folder : folder + "/")"
    }

    private var selectedItem: FileItem? {
        guard rows.indices.contains(resultsTable.selectedRow), case .item(let item) = rows[resultsTable.selectedRow]
        else { return nil }
        return item
    }

    private var selectedResult: URL? { selectedItem?.url }

    private func clearResults() {
        let dropped = (rows, resultURLs)
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(dropped) {} }
        rows = []
        (resultURLs, foundFiles, foundDirectories) = ([], 0, 0)
        showsDuplicates = false
        resultsTable.reloadData()
        statusLabel.stringValue = ""
        updateButtons()
    }

    private func show(_ set: ResultSet) {
        (rows, showsDuplicates) = (set.rows, set.showsDuplicates)
        (resultURLs, foundFiles, foundDirectories) = (set.urls, set.files, set.directories)
        resultsTable.reloadData()
        if case .summary(let text)? = rows.first { statusLabel.stringValue = text }
        updateButtons()
    }

    @objc private func showEarlier() {
        guard !isSearching, earlierIndex > 0 else { return }
        earlierIndex -= 1
        show(earlier[earlierIndex])
    }

    @objc private func showLater() {
        guard !isSearching, earlierIndex < earlier.count - 1 else { return }
        earlierIndex += 1
        show(earlier[earlierIndex])
    }

    /// New search: empties the list and goes back to the form.
    @objc func newSearch() {
        guard !isSearching else { return }
        clearResults()
        form.tabView.selectTabViewItem(at: 0)
        window?.makeFirstResponder(form.searchForField)
    }

    private var shiftIsDown: Bool { NSEvent.modifierFlags.contains(.shift) }

    /// Go to file: closes the window and puts the panel's cursor on the result; with Shift in
    /// a new tab. A single result is taken even when it is not the selected line.
    @objc func goToFile() {
        guard let url = selectedResult ?? (resultURLs.count == 1 ? resultURLs[0] : nil) else { return }
        close()
        if shiftIsDown { kernel.panels.source.tabs.openTab() }
        kernel.commands.perform(.changeDirectory, .location(url))
    }

    /// Feed to listbox: the results become the list of the source panel, through whichever
    /// plugin shows file lists as folders (spec 09 › Feed to listbox); with Shift in a new tab.
    /// The window closes and does not keep these results.
    @objc func feedToListbox() {
        let urls = resultURLs
        guard !isSearching, !urls.isEmpty, let lists = kernel.services.find((any FileListService).self) else { return }
        let inNewTab = shiftIsDown
        close()
        let panel = kernel.panels.source
        if inNewTab { panel.tabs.openTab() }
        // The search leaves out a file it has reported: the list holds no location twice.
        lists.show(urls, title: "Search result", in: panel, isUnique: true)
        clearResults()
        (earlier, earlierIndex) = ([], 0)
    }

    @objc private func viewResult() {
        if let url = selectedResult { kernel.commands.perform(.view, .location(url)) }
    }

    @objc private func editResult() {
        if let url = selectedResult { kernel.commands.perform(.edit, .location(url)) }
    }

    /// Enter goes to the file and Cmd+C copies the whole list; View and Edit answer to whatever
    /// keys they are bound to in the main window.
    private func handleResultKey(_ event: NSEvent) -> Bool {
        if Shortcut(.returnKey).matches(event) || Shortcut(.returnKey, .shift).matches(event) {
            goToFile()
        } else if Shortcut.cmd("c").matches(event) || Shortcut(.character("c"), .control).matches(event) {
            copyListToPasteboard()
        } else if let command = kernel.keyBindings.command(for: event), command == .view || command == .edit,
            let url = selectedResult
        {
            kernel.commands.perform(command, .location(url))
        } else {
            return false
        }
        return true
    }

    /// The list as text: one line per result, an empty line between groups of duplicates.
    var copyText: String {
        Self.copyText(of: rows, showsDuplicates: showsDuplicates, fileSystems: kernel.fileSystems)
    }

    private static func copyText(of rows: [Row], showsDuplicates: Bool, fileSystems: FileSystemRegistry) -> String {
        var lines: [String] = []
        lines.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case .summary(let text): lines.append(text)
            case .separator: lines.append("")

            case .item(let item):
                lines.append(
                    Self.text(
                        of: item, showsDuplicates: showsDuplicates, fileSystems: fileSystems))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Cmd+C: a long list is turned into text on a background queue (that takes a second for
    /// millions of rows) and put on the pasteboard when it is ready; a list shown again or
    /// copied again meanwhile drops the older request.
    private func copyListToPasteboard() {
        copyRequest += 1
        let request = copyRequest
        let (rows, showsDuplicates, fileSystems) = (self.rows, self.showsDuplicates, kernel.fileSystems)
        func put(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        guard rows.count > Self.smallList else {
            put(copyText)
            return
        }
        statusLabel.stringValue = "[Copying the list...]"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = Self.copyText(
                of: rows, showsDuplicates: showsDuplicates, fileSystems: fileSystems)
            DispatchQueue.main.async {
                guard let self, self.copyRequest == request else { return }
                put(text)
                if case .summary(let summary)? = self.rows.first, !self.isSearching {
                    self.statusLabel.stringValue = summary
                }
            }
        }
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("path")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingMiddle
                return label
            }()
        cell.stringValue = text(of: rows[row])
        if case .item = rows[row] { cell.textColor = .labelColor } else { cell.textColor = .secondaryLabelColor }
        return cell
    }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .separator = rows[row] { return false }
        return true
    }

    /// After a search the status line shows the size, date and permissions of the result
    /// under the cursor, which the list itself does not.
    func tableViewSelectionDidChange(_: Notification) {
        updateButtons()
        guard !isSearching else { return }
        if let item = selectedItem {
            let size = item.isDirectory ? "<DIR>" : Format.bytes(item.size)
            statusLabel.stringValue =
                "\(item.name)   \(size)  \(Format.date(item.modified))  \(Format.permissions(item.permissions))"
        } else if case .summary(let text)? = rows.first {
            statusLabel.stringValue = text
        }
    }

    func windowDidBecomeKey(_: Notification) {
        form.setSelectionAvailable(hasSelectedItems)
    }

    func windowWillClose(_: Notification) {
        let wasSearching = isSearching
        search?.cancel()
        spotlight?.stop()
        (search, spotlight) = (nil, nil)
        // Half a result list is not kept.
        if wasSearching { clearResults() } else { updateButtons() }
        // Only the list on show outlives the window; the older ones are not kept for good.
        if earlier.count > 1, earlier.indices.contains(earlierIndex) {
            (earlier, earlierIndex) = ([earlier[earlierIndex]], 0)
        }
        updateButtons()
        onClose(self)
    }
}
