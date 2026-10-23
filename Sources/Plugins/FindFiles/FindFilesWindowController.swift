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
internal final class FindFilesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    /// The setting "Keep the results of the last search when the window is opened again".
    internal static let keepResultsKey = "findFiles.keepResults"
    /// The setting of how many entries the histories of the search fields keep, an index of `historyLengths`.
    internal static let historyLengthKey = "findFiles.historyLength"
    /// The setting "Search with Spotlight unless told otherwise".
    internal static let spotlightKey = "findFiles.spotlight"
    /// The lengths the histories of the search fields can have.
    internal static let historyLengths = [10, 20, 50, 100]
    /// The most hits a search of the window lists; it stops there and says so.
    nonisolated internal static let resultLimit = 2_000_000
    /// The most rows handed to the list in one piece.
    nonisolated internal static let batchSize = 2_000
    /// Lists up to this many rows are worked on the main thread where that is simpler.
    internal static let smallList = 20_000
    /// The most earlier searches kept.
    internal static let earlierLimit = 10

    /// The four tabs of the search.
    internal let form: SearchForm
    /// Called when the window was closed.
    internal var onClose: (FindFilesWindowController) -> Void = { _ in
        // Nobody listens unless the plugin keeps the window in a list.
    }
    /// Called when a search has ended, also a cancelled one.
    internal var onFinished: () -> Void = {
        // Only tests wait for the end of a search.
    }
    /// Where Cmd+C puts the list: the clipboard, or a pasteboard of a test's own.
    internal var pasteboard = NSPasteboard.general
    /// The modifier keys held down now (Shift opens a new tab); a test says which.
    internal var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// How far the window goes.
    internal var limits = Limits()
    /// The search that runs now, if any.
    internal private(set) var search: FileSearch?
    /// Makes the question to Spotlight from its text, the folders it looks in and the most paths
    /// it reads.
    ///
    /// Tests put a question in its place that answers when they say.
    internal var makeSpotlight: (String, [URL], Int) -> any SpotlightQuestion = { text, scopes, limit in
        SpotlightSearch(text, scopes: scopes, limit: limit, queue: OperationQueue())
    }
    /// Puts the window on screen.
    ///
    /// Tests replace it, so that no window shows in the session they run in, and look at what it
    /// was asked to show.
    internal var present: @MainActor (NSWindowController) -> Void = { $0.showWindow(nil) }

    /// "Start search".
    internal let startButton = NSButton(title: "Start search", target: nil, action: nil)
    /// "Close", or "Cancel" while a search runs.
    internal let cancelButton = NSButton(title: "Close", target: nil, action: nil)
    /// `<`: the search before.
    internal let backButton = NSButton(title: "<", target: nil, action: nil)
    /// `>`: the search after.
    internal let forwardButton = NSButton(title: ">", target: nil, action: nil)
    /// "F2 Search in found files/folders".
    internal let inFoundBox = NSButton(checkboxWithTitle: "F2 Search in found files/folders", target: nil, action: nil)
    /// The result list.
    internal let resultsTable = ResultsTableView()
    /// The line under the list: the folder being searched, the summary, or the result under the cursor.
    internal let statusLabel = NSTextField(labelWithString: "")
    /// View, Edit and Go to file, which need a result under the cursor.
    internal var resultButtons: [NSButton] = []
    /// "Feed to listbox".
    internal var feedButton = NSButton()
    /// "New search".
    internal var newSearchButton = NSButton()

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// Whether hidden files are found: the panels show them.
    internal var includeHidden = false
    /// The folder the window was opened for; relative start directories count from here.
    internal var startDirectory = URL(fileURLWithPath: "/")
    /// The lines of the list.
    internal var rows: [Row] = []
    /// The locations of the items in `rows`, in list order; kept as rows arrive so that nothing
    /// needs to walk the list for them.
    internal var resultURLs: [URL] = []
    /// How many files the list holds.
    internal var foundFiles = 0
    /// How many folders the list holds.
    internal var foundDirectories = 0
    /// Counts the requests to copy the list, so that an older one is dropped.
    internal var copyRequest = 0
    /// The list holds groups of duplicates.
    internal var showsDuplicates = false
    /// The lists of the last searches, oldest first.
    internal var earlier: [ResultSet] = []
    /// Which of `earlier` the list shows.
    internal var earlierIndex = 0
    /// The question to Spotlight that is waiting for its answer, if any.
    internal var spotlight: (any SpotlightQuestion)?
    private let store: SearchStore

    /// Whether a search runs.
    internal var isSearching: Bool { search != nil }

    /// Whether anything is marked in the source panel; asked often, so it does not look at the items.
    private var hasSelectedItems: Bool { kernel.panels.source.model.selectionCount > 0 }

    /// The marked items of the source panel, for "Only search in selected directories/files".
    private var selectedItems: [URL] {
        let model = kernel.panels.source.model
        return model.items.filter { model.isSelected($0) }.map(\.url)
    }

    /// The window of `cm_SearchFor`, titled "Find Files".
    internal convenience init(kernel: Kernel) {
        self.init(kernel: kernel, title: "Find Files")
    }

    /// A window titled `title` that searches through the file systems of `kernel`.
    internal init(kernel: Kernel, title: String) {
        self.kernel = kernel
        store = SearchStore(settings: kernel.settings)
        form = SearchForm(
            fields: SearchField.all(fileSystems: kernel.fileSystems, columns: kernel.columns),
            store: store,
            interaction: kernel.interaction
        )
        let window = FindWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 520)
        window.center()
        super.init(window: window)
        window.delegate = self
        // Esc interrupts a running search; when idle it closes the window.
        window.onEscape = { [weak self] in
            guard let self, isSearching else {
                return false
            }
            cancelSearch()
            return true
        }
        window.onF2 = { [weak self] in
            guard let self, inFoundBox.isEnabled else {
                return
            }
            inFoundBox.state = inFoundBox.state == .on ? .off : .on
        }
        form.onSubmit = { [weak self] in
            if self?.isSearching == false {
                self?.startSearch()
            }
        }
        var initial = SearchSettings()
        initial.useSpotlight = kernel.settings.flag(Self.spotlightKey, default: false)
        form.settings = initial
        buildContent(in: window)
    }

    /// The window is made in code, never from an archive.
    internal required init?(coder _: NSCoder) { nil }

    /// Shows the window with "Search in" set to `directory`.
    ///
    /// Results are viewed, edited and shown in the panel through the kernel's commands.
    internal func show(startingIn directory: URL, includeHidden: Bool) {
        prepare(startingIn: directory, includeHidden: includeHidden)
        present(self)
        window?.makeFirstResponder(form.searchForField)
    }

    /// Everything `show` does except putting the window on screen.
    ///
    /// The names and the text stay from last time; the Advanced tab starts empty (spec 09 › What is
    /// remembered).
    internal func prepare(startingIn directory: URL, includeHidden: Bool) {
        // The list is drawn from this window again (closing let go of it).
        resultsTable.dataSource = self
        resultsTable.delegate = self
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

    /// Enables the buttons that make sense now.
    internal func updateButtons() {
        cancelButton.title = isSearching ? "Cancel" : "Close"
        startButton.isEnabled = !isSearching
        let hasResult = selectedResult != nil
        for button in resultButtons {
            button.isEnabled = hasResult
        }
        let hasItems = !isSearching && foundFiles + foundDirectories > 0
        feedButton.isEnabled = hasItems && kernel.services.find((any FileListService).self) != nil
        newSearchButton.isEnabled = !isSearching && !rows.isEmpty
        inFoundBox.isEnabled = hasItems
        if !hasItems {
            inFoundBox.state = .off
        }
        backButton.isEnabled = !isSearching && earlierIndex > 0
        forwardButton.isEnabled = !isSearching && earlierIndex < earlier.count - 1
    }

    /// Starts the search the form describes.
    ///
    /// A form that cannot be searched with (a broken regular expression) is reported instead.
    internal func startSearch() {
        let settings = form.settings
        // Start directories the user typed (not the ones the window was opened with or a saved
        // search brought) are the user's own choice of their servers, if they name any.
        if settings.searchIn != form.placedSearchIn {
            for part in settings.searchIn.split(separator: ";") {
                kernel.userTyped(location: String(part), relativeTo: startDirectory)
            }
        }
        var query = settings.query(
            relativeTo: startDirectory,
            fileSystems: kernel.fileSystems,
            includeHidden: includeHidden,
            selected: settings.onlySelected ? selectedItems : []
        )
        if inFoundBox.state == .on {
            query.scope = .only(resultURLs)
        }
        query.resultLimit = limits.results
        let started = FileSearch(query, fileSystems: kernel.fileSystems, columns: kernel.columns)
        if let problem = started.problem {
            kernel.interaction.report(problem, title: "The search cannot start")
            return
        }
        let lengths = Self.historyLengths
        form.rememberHistory(
            limit: lengths[min(max(kernel.settings.index(Self.historyLengthKey, default: 1), 0), lengths.count - 1)]
        )
        search = started
        rows = [.summary("[Searching...]")]
        (resultURLs, foundFiles, foundDirectories) = ([], 0, 0)
        showsDuplicates = false
        resultsTable.reloadData()
        statusLabel.stringValue = "[Searching...]"
        updateButtons()
        if settings.useSpotlight, SpotlightQuery.isAvailable(for: query) {
            askSpotlight(
                makeSpotlight(SpotlightQuery.string(for: query), query.directories, limits.spotlight),
                for: started
            )
        } else if query.duplicates.isActive {
            walkForDuplicates(started)
        } else {
            walk(started)
        }
    }

    /// Ends the search. `built` replaces what was listed while it ran (Spotlight's answer,
    /// duplicates in groups); without it the rows that arrived are kept and only the summary
    /// line is filled in. `notes` say what did not go as asked.
    internal func finish(built: Built?, notes: [String]) {
        let wasCancelled = search?.cancellation.isCancelled == true
        search = nil
        if let built {
            (rows, resultURLs, foundFiles, foundDirectories, showsDuplicates) = (
                built.rows, built.urls, built.files, built.directories, built.showsDuplicates
            )
        }
        let found = foundFiles + foundDirectories
        let counts = "\(foundFiles) files and \(foundDirectories) directories"
        var summary =
            wasCancelled
            ? (found == 0 ? "[Search cancelled]" : "[Search cancelled, \(counts) found so far]")
            : found == 0 ? "[No files found]" : "[\(counts) found]"
        if !notes.isEmpty {
            summary  // Every summary ends with its bracket.
            = String(summary.dropLast()) + " - " + notes.joined(separator: "; ") + "]"
        }
        rows[0] = .summary(summary)
        if built != nil {
            resultsTable.reloadData()
        } else {
            resultsTable.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
        }
        statusLabel.stringValue = summary
        keepResults()
        if found > 0 {
            resultsTable.selectRowIndexes([1], byExtendingSelection: false)
            window?.makeFirstResponder(resultsTable)
        }
        updateButtons()
        onFinished()
    }

    /// The search of the source panel's selection is offered while the panel has one.
    internal func windowDidBecomeKey(_: Notification) {
        form.setSelectionAvailable(hasSelectedItems)
    }

    /// A search that still runs is stopped, and its half a list goes.
    internal func windowWillClose(_: Notification) {
        let wasSearching = isSearching
        search?.cancel()
        spotlight?.stop()
        (search, spotlight) = (nil, nil)
        // Half a result list is not kept.
        if wasSearching {
            clearResults()
        } else {
            updateButtons()
        }
        // Only the list on show outlives the window; the older ones are not kept for good.
        if earlier.count > 1, earlier.indices.contains(earlierIndex) {
            (earlier, earlierIndex) = ([earlier[earlierIndex]], 0)
        }
        updateButtons()
        // A closed window asks nothing more of the kernel, which may be gone before its views
        // are when the program ends; `prepare` takes the list up again.
        resultsTable.dataSource = nil
        resultsTable.delegate = nil
        onClose(self)
    }
}
