import AFMContracts
import AFMKernel
import AppKit

/// What a panel tells its surroundings.
protocol PanelHost: AnyObject {
    func panelDidBecomeActive(_ panel: PanelViewController)
    /// The panel shows another directory or another tab.
    func panelDidChangeLocation(_ panel: PanelViewController)
    /// The cursor may be on another item now, or the panel started or stopped reading.
    func panelCursorDidChange(_ panel: PanelViewController)
    /// The marked items changed.
    func panelSelectionDidChange(_ panel: PanelViewController)
    /// The panel started or stopped reading, or the folder it shows is now listed, and nothing
    /// a plugin follows has changed: the cursor is where it was, on the item it was on.
    func panelActivityDidChange(_ panel: PanelViewController)
    /// A reading of exactly this location that is already on its way (the folder under the
    /// cursor being read ahead), for the panel to take over instead of reading a second time.
    func panel(_ panel: PanelViewController, joinReadingOf location: URL, showHidden: Bool) -> ReadAhead.Joined?
    /// The places of the volume list, as far as they are known; they are asked for in the
    /// background, and `placesDidChange` tells the panel when more are known.
    func placesForVolumeList(of panel: PanelViewController) -> [Place]
    /// The drive that can be ejected (a USB stick, a disk image, a share) a location is on,
    /// from what is known of the places; nil for one that cannot be ejected.
    func ejectableVolume(containing location: URL) -> Place?
}

/// One file panel on screen: drive line, folder tabs, path bar, file list and status line
/// (spec 03 › Panel anatomy).
///
/// It draws the active tab of its `PanelTabs` and redraws whenever a model reports a change,
/// so nobody has to tell it. Keys and clicks become commands; what the commands do is up to
/// the plugins.
///
/// **Threading.** The controller and the models belong to the main thread. Directories are
/// read on background threads (`PanelLoading`) and applied here; a slow or very large
/// directory appears piece by piece while it is still being read. Nothing here asks a file
/// system anything on the main thread, and nothing that may wait on one runs on the system's
/// shared thread pool (`Background`). What comes back from a background thread arrives through
/// the run loop (`MainLoop`), so that a completion may show a dialog.
///
/// **Reading again.** A folder that others change is read again quietly: nothing is redrawn,
/// announced or taken away from the user (the in-place editor, a quick view) unless the
/// listing really differs. Between two such readings lies at least `minimumRereadInterval`,
/// and twice the time the last reading took, so a folder that changes all the time costs a
/// bounded share of the machine however large it is.
///
/// **Remembered listings.** A location the kernel's listing cache remembers is shown from
/// there at once and read afresh behind (`showRemembered`); every reading that reaches its end
/// is handed to the cache on the background thread that made it. The cache is the one thing
/// here that is shared between the main thread and the readers, and it is safe on any thread.
///
/// **Views.** The Full view is a table; Brief and Thumbnails are drawn by `FileGridView`
/// (spec 03 › View types). Only one of them is on screen. Cursor, marking, keys, menus, the
/// in-place editor and drag and drop are handled here, once, for all of them; the parts that
/// differ by view are in the extensions of this class.
final class PanelViewController: NSViewController, PanelHandle, PanelOverlayHost, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate
{
    let tabs: PanelTabs
    let kernel: Kernel
    weak var host: any PanelHost?

    var commands: CommandRegistry { kernel.commands }

    /// Lists from this length on are put in a new order in the background (as with the sort commands).
    static let backgroundSortThreshold = 20_000

    let tableView = FileTableView()
    private let volumeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let freeLabel = NSTextField(labelWithString: "")
    let tabBar = TabBarView()
    let pathBar = PathBarView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var renameField: NSTextField?
    /// The item whose name is being edited: it keeps the editor for as long as it is in the list.
    private var renaming: (tab: ObjectIdentifier, location: String, name: String)?
    /// The rename that follows a click on the item the cursor is already on, waiting for the
    /// double-click time to pass.
    private var pendingRename: (() -> Void)?
    /// Set while the table is updated from the model, so the cursor is not read back.
    var syncing = false
    /// The list of the Brief and Thumbnails views, with its header of sort buttons.
    let gridView = FileGridView()
    let sortHeader = SortHeaderView()
    private let tableScroll = NSScrollView()
    private let gridBox = NSStackView()
    /// The menu of the column header: the views and the columns to show.
    let headerMenu = NSMenu()
    let quickFilterBar = QuickFilterBar()
    /// The quick filter of each tab that has one.
    var quickFilters: [ObjectIdentifier: QuickFilter] = [:]
    /// The texts of the plugin columns and the pictures of the Thumbnails view, for the folder on screen.
    let columnValues = ColumnValueStore()
    let thumbnails = ThumbnailStore()
    /// The folder the two stores above hold values for.
    private var storedLocation: String?
    /// The user's options for the lists; set by the coordinator.
    var settings = PanelSettings() {
        didSet {
            rowColor = nil
            if isViewLoaded { redraw() }
        }
    }
    /// The widths of the columns of the Full view as they were last seen, by identifier.
    var columnWidths: [String: Double] = [:]
    /// Called when the view, the columns or their widths changed, so they can be remembered.
    var onViewStateChanged: (() -> Void)?
    /// The tab the table currently shows; differs from `model` for a moment after a tab switch.
    private weak var shownTab: PanelModel?
    /// One running read per tab; starting another cancels the one before.
    private var loads: [ObjectIdentifier: Load] = [:]
    /// Folder-size calculations started with Space, per tab; cancelled when the tab moves on to
    /// another folder (a reading of the same folder keeps them).
    private var sizeCalculations: [ObjectIdentifier: CancellationFlag] = [:]
    /// Sizes that came in during one turn of the main loop, per tab, with the folder they were
    /// measured in; the tab takes them together.
    private var arrivedSizes:
        [ObjectIdentifier: (directory: URL, flag: CancellationFlag, sizes: [(name: String, size: Int64)])] = [:]
    /// What a tab showed before a slow reading entered another folder, empty (`PanelModel.open`),
    /// for as long as that reading has delivered nothing. It belongs to the tab, not to a reading:
    /// a reading that overtakes the one that opened the folder still goes back to this if it
    /// fails, instead of to the empty folder.
    private var openedFrom: [ObjectIdentifier: PanelModel.Snapshot] = [:]
    /// The quick filter the tab had when that snapshot was taken: it comes back with it.
    private var openedFromFilter: [ObjectIdentifier: QuickFilter] = [:]
    /// Tabs whose folder changed while a reading or a rename was under way, or too soon after
    /// the last reading: read once more when that is over, so the change is not lost. The
    /// value is the folders (`URL.locationKey`) the change may have been in: the one the tab
    /// showed and the one it was on its way to. A tab that ends up in neither has nothing to
    /// make up for.
    private var dirty: [ObjectIdentifier: Set<String>] = [:]
    /// Who waits for a reload that was put off, per tab; told when the reading that makes up
    /// for it has ended.
    private var waitingCompletions: [ObjectIdentifier: [() -> Void]] = [:]
    /// When each tab's folder was last read to its end (in the system's uptime), and how long
    /// that took from the request to the list on screen.
    private var lastRead: [ObjectIdentifier: (ended: TimeInterval, cost: TimeInterval)] = [:]
    /// The timers of the readings that were put off, per tab, as the functions that stop them.
    private var rereadTimers: [ObjectIdentifier: () -> Void] = [:]
    /// The least time between the end of one reading of a folder and the start of a quiet
    /// re-reading; twice the cost of the last reading when that is more.
    static let minimumRereadInterval: TimeInterval = 0.5
    /// The tab and folder the host was last told the panel shows.
    private var announced: (tab: ObjectIdentifier, location: String)?
    /// Set when the panel was shut down: nothing is read any more.
    private var isShutDown = false
    /// The next redraw takes the whole list anew instead of bringing the rows up to date.
    var needsFullReload = true
    /// The item the cursor was shown on last: the view scrolls to the cursor when this changes.
    var shownCursor: (tab: ObjectIdentifier, name: String?)?
    var shownCursorRow: Int?
    /// Whether the visible cells of the grid were last drawn marked, by row; reset whenever the
    /// grid shows other rows.
    var gridMarks: [Int: Bool] = [:]
    /// The colour of the row whose cells were last asked for, so a row costs one evaluation of
    /// the colour rules and not one per column.
    var rowColor: (name: String?, hidden: Bool, selected: Bool, color: NSColor)?
    /// Typing in the quick filter field waits a moment for more before the list is filtered.
    var pendingQuickFilter: (() -> Void)?
    /// The text waiting in `pendingQuickFilter`, with the tab it was typed in.
    var pendingQuickFilterTyping: (tab: PanelModel, text: String)?
    /// The filtering of a long list that runs in the background, per tab, by number; only the
    /// latest one of a tab is taken over, and removing the entry cancels it.
    var filterJobs: [ObjectIdentifier: Int] = [:]
    var filterJobCount = 0
    /// Waits for the file systems to report new figures of a volume (free space).
    private var volumeObserver: any NSObjectProtocol?
    private var iconObserver: any NSObjectProtocol?
    /// The tabs whose volume is being asked about, and those that have to be asked again when
    /// the answer is there: one question at a time per tab, however often the figures change
    /// and however long the file system takes to answer.
    private var volumeAsking: [ObjectIdentifier: CancellationFlag] = [:]
    private var volumeAskAgain: Set<ObjectIdentifier> = []
    /// Finding a file by typing: what was typed, and the search of a long list under way.
    var typeSelect = TypeSelect()
    var typeFind: CancellationFlag?
    private var volumeMenuIsOpen = false
    /// What the drag that starts in the table puts on the pasteboard, between the table asking
    /// for the grabbed row and the drag beginning.
    var pendingDragItems: [NSPasteboardItem] = []

    var viewMode = PanelViewMode.full {
        didSet {
            guard viewMode != oldValue else { return }
            applyViewMode()
            onViewStateChanged?()
        }
    }

    var extraColumns: [String] = [] {
        didSet {
            guard extraColumns != oldValue else { return }
            rebuildExtraColumns()
            onViewStateChanged?()
        }
    }

    /// The place of the file list, whichever view shows it; an overlay covers it.
    private var listArea: NSView?

    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let overlay, let listArea, isViewLoaded else { return }
            overlay.translatesAutoresizingMaskIntoConstraints = false
            listArea.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: listArea.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: listArea.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: listArea.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: listArea.trailingAnchor)
            ])
        }
    }

    var isActive = false {
        didSet {
            pathBar.isActive = isActive
            tableView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
            // Only the cursor bar looks different.
            gridView.redraw(row: model.cursor)
        }
    }

    init(tabs: PanelTabs, kernel: Kernel) {
        self.tabs = tabs
        self.kernel = kernel
        super.init(nibName: nil, bundle: nil)
        tabs.onChange = { [weak self] in self?.tabsChanged() }
        observeModels()
        volumeObserver = NotificationCenter.default.addObserver(
            forName: FileSystemRegistry.volumeInfoDidChange, object: nil,
            queue: .main
        ) { [weak self] note in
            self?.volumeInfoChanged(note)
        }
        iconObserver = NotificationCenter.default.addObserver(forName: IconStore.didArrive, object: nil, queue: .main) {
            [weak self] note in
            if let paths = note.userInfo?[IconStore.pathsKey] as? Set<String> { self?.iconsArrived(for: paths) }
        }
        // Where the panel starts is known to everybody; what is announced is where it goes from there.
        announced = (ObjectIdentifier(tabs.active), tabs.active.directory.locationKey)
    }

    deinit {
        if let volumeObserver { NotificationCenter.default.removeObserver(volumeObserver) }
        if let iconObserver { NotificationCenter.default.removeObserver(iconObserver) }
    }

    /// A file system reports new figures for a volume: every tab that shows a place at or below its
    /// root asks for them again, in the background, and takes the answer unless it moved on.
    private func volumeInfoChanged(_ note: Notification) {
        guard let provider = note.object as? (any FileSystemProvider) else { return }
        let root = note.userInfo?[FileSystemRegistry.volumeRootKey] as? URL
        for tab in tabs.tabs {
            let directory = tab.directory
            guard let own = try? kernel.fileSystems.provider(for: directory),
                (own as AnyObject) === (provider as AnyObject),
                root.map({ directory.isSameLocation(as: $0) || directory.isInside($0) }) ?? true
            else { continue }
            askVolume(of: tab, from: provider)
        }
    }

    /// Asks the file system about the volume of a tab's folder, on one of the kernel's threads
    /// for calls that block (`BlockingCalls`): the same question about the same folder is out
    /// once, whoever asks (a reading of the folder asks it too), and it is given up when the
    /// tab is closed or the window goes. While a question is out, no second one is sent for
    /// the tab: it is asked about again when the answer has come, so the last figures always
    /// win and a file system that does not answer holds one thread, not one per report.
    private func askVolume(of tab: PanelModel, from provider: any FileSystemProvider) {
        let id = ObjectIdentifier(tab)
        guard volumeAsking[id] == nil else {
            volumeAskAgain.insert(id)
            return
        }
        let flag = CancellationFlag()
        volumeAsking[id] = flag
        let directory = tab.directory
        BlockingCalls.answer(
            from: provider as AnyObject, to: "volume " + directory.locationKey, cancellation: flag,
            { provider.volume(of: directory, cancellation: $0) },
            then: { [weak self, weak tab] (answer: VolumeInfo??) in
                guard let self, volumeAsking[id] === flag else { return }
                volumeAsking[id] = nil
                let again = volumeAskAgain.remove(id) != nil
                // A tab that is gone; its address may belong to another one by now.
                guard let tab, !flag.isCancelled, tabs.tabs.contains(where: { $0 === tab }) else { return }
                if again {
                    askVolume(of: tab, from: provider)
                } else if let volume = answer, tab.directory.isSameLocation(as: directory) {
                    tab.setVolume(volume)
                }
            })
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    // MARK: Layout

    override func loadView() {
        volumeButton.bezelStyle = .recessed
        volumeButton.addItem(withTitle: "/")
        volumeButton.menu?.delegate = self
        volumeButton.setContentHuggingPriority(.required, for: .horizontal)
        freeLabel.font = .systemFont(ofSize: 11)
        freeLabel.textColor = .secondaryLabelColor
        freeLabel.lineBreakMode = .byTruncatingTail
        freeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let driveLine = NSStackView(views: [
            volumeButton, freeLabel, spacer,
            smallButton("/", .goToRoot), smallButton("..", .goToParent)
        ])
        driveLine.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        driveLine.spacing = 6

        tabBar.onSelect = { [weak self] index in self?.performFocused(.activateTab, .index(index)) }
        tabBar.onClose = { [weak self] index in self?.performFocused(.closeTab, .index(index)) }
        tabBar.onNewTab = { [weak self] in self?.performFocused(.newTab) }
        tabBar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabBar.menuProvider = { [weak self] index in self?.tabMenu(forTab: index) }
        pathBar.onClick = { [weak self] clicks in
            self?.focus()
            if clicks == 2 { self?.commands.perform(.editPath) }
        }
        pathBar.onNavigate = { [weak self] location in self?.performFocused(.changeDirectory, .location(location)) }
        pathBar.menuProvider = { [weak self] in self?.pathMenu() }
        pathBar.onEject = { [weak self] in
            guard let self, let volume = host?.ejectableVolume(containing: model.directory) else { return }
            performFocused(.ejectVolume, .location(volume.url))
        }

        for column in FileListColumn.allCases {
            let tableColumn = column.makeTableColumn()
            if let width = columnWidths[column.rawValue] { tableColumn.width = CGFloat(width) }
            tableView.addTableColumn(tableColumn)
        }
        tableView.panel = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.style = .plain
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        // Finding a file by typing is the panel's own (`typeToFind`): the table's would ask
        // for the name of every row, on the main thread, for each key.
        tableView.allowsTypeSelect = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.registerForDraggedTypes(PanelDrop.acceptedTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        let scroll = makeListArea(tableScroll: tableScroll, gridBox: gridBox)
        listArea = scroll
        tableScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(tableScrolled), name: NSView.boundsDidChangeNotification,
            object: tableScroll.contentView)
        quickFilterBar.isHidden = true
        quickFilterBar.onChange = { [weak self] text in self?.quickFilterEdited(text) }
        quickFilterBar.onCancel = { [weak self] in self?.removeQuickFilter() }
        quickFilterBar.onReturn = { [weak self] in self?.leaveQuickFilterField() }
        columnValues.onArrival = { [weak self] names in self?.columnValuesArrived(for: names) }
        thumbnails.onArrival = { [weak self] name in self?.thumbnailArrived(for: name) }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusLine = NSStackView(views: [statusLabel, statusSpacer, activityIndicator])
        statusLine.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

        let stack = NSStackView(views: [driveLine, tabBar, pathBar, scroll, quickFilterBar, statusLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for part in stack.arrangedSubviews {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = stack
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        rebuildExtraColumns()
        applyViewMode()
    }

    /// The table shows other rows: the values of plugin columns that wait for rows that went
    /// out of sight are no longer wanted, so they do not hold up those that are.
    @objc private func tableScrolled() {
        guard columnValues.hasWaiting, !showsGrid else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let names = Set(
            (visible.location..<(visible.location + visible.length)).compactMap { model.item(atRow: $0)?.name })
        columnValues.dropWaiting(except: names)
    }

    /// A drive-line button that runs a command in this panel.
    private func smallButton(_ title: String, _ command: CommandID) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(driveLineButtonPressed(_:)))
        button.bezelStyle = .recessed
        button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        button.refusesFirstResponder = true
        return button
    }

    @objc private func driveLineButtonPressed(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { performFocused(CommandID(rawValue: name)) }
    }

    /// Commands act on the source panel, so a click in this panel makes it the source first.
    func performFocused(_ command: CommandID, _ argument: CommandArgument = .none) {
        focus()
        commands.perform(command, argument)
    }

    /// Runs the command that stands for a standard editing action (Cmd+C and the like).
    func perform(_ role: EditingRole) {
        if let command = commands.command(with: role) { commands.perform(command) }
    }

    // MARK: Following the models

    private func observeModels() {
        for tab in tabs.tabs {
            tab.onChange = { [weak self, weak tab] change in
                guard let self, let tab else { return }
                guard tab === model else { return }
                modelChanged(change)
            }
        }
    }

    private func modelChanged(_ change: PanelModel.Change) {
        guard isViewLoaded else { return }
        switch change {
        case .contents:
            // A quick filter whose folder was left is taken away, which reports the next change.
            if dropStaleQuickFilter(of: model) { return }
            // A reading in progress goes on in the order the list has now.
            loads[ObjectIdentifier(model)]?.order.value = model.wantedSort
            redraw()

        case .selection:
            redrawSelection()
            host?.panelSelectionDidChange(self)

        case .cursor:
            showCursor(forceScroll: true)
            if viewMode == .brief { updateStatus() }
        }
        host?.panelCursorDidChange(self)
    }

    /// A tab was opened, closed or activated.
    private func tabsChanged() {
        observeModels()
        let open = Set(tabs.tabs.map(ObjectIdentifier.init))
        // What belongs to a tab that is gone goes with it (and must not meet a new tab that
        // happens to get the same address).
        for (tab, load) in loads where !open.contains(tab) {
            load.flag.cancel()
            // Whoever waits for the reading of a tab that is gone hears that it came to nothing.
            load.supersede()
        }
        loads = loads.filter { open.contains($0.key) }
        for tab in Array(waitingCompletions.keys) where !open.contains(tab) { flushWaitingCompletions(of: tab) }
        for (tab, stop) in rereadTimers where !open.contains(tab) { stop() }
        rereadTimers = rereadTimers.filter { open.contains($0.key) }
        lastRead = lastRead.filter { open.contains($0.key) }
        for (tab, flag) in sizeCalculations where !open.contains(tab) { flag.cancel() }
        sizeCalculations = sizeCalculations.filter { open.contains($0.key) }
        // Text typed a moment ago into the tab that was left belongs to that tab: it is applied there now.
        if let typing = pendingQuickFilterTyping, typing.tab !== model {
            if open.contains(ObjectIdentifier(typing.tab)) {
                flushPendingQuickFilter()
            } else {
                dropPendingQuickFilter()
            }
        }
        quickFilters = quickFilters.filter { open.contains($0.key) }
        filterJobs = filterJobs.filter { open.contains($0.key) }
        volumeAskAgain.formIntersection(open)
        for (tab, flag) in volumeAsking where !open.contains(tab) { flag.cancel() }
        volumeAsking = volumeAsking.filter { open.contains($0.key) }
        for tab in Array(openedFrom.keys) where !open.contains(tab) { dropSnapshot(of: tab) }
        dirty = dirty.filter { open.contains($0.key) }
        if let shown = shownCursor, !open.contains(shown.tab) { shownCursor = nil }
        // A tab opened while a quick filter is on is a copy of that tab, filter included, but has
        // no quick filter of its own (each tab has its own): it gets the display filter below
        // the quick one, so it is not left with a filter nothing shows and Esc cannot take away.
        for tab in tabs.tabs where quickFilters[ObjectIdentifier(tab)] == nil {
            guard let title = tab.filter?.title,
                let source = quickFilters.values.first(where: {
                    !$0.text.isEmpty && $0.title == title && $0.directory.isSameLocation(as: tab.directory)
                })
            else { continue }
            setFilter(source.base, of: tab)
        }
        guard isViewLoaded else { return }
        let tabSwitched = shownTab !== model
        redraw()
        guard tabSwitched else { return }
        // A tab that was never shown is read now; one that was in the background may be out of date.
        // One that is being read already is not asked again.
        if model.isListed {
            reload(model, focus: nil, quietly: true, markDirty: false, completion: nil)
        } else if loads[ObjectIdentifier(model)] == nil {
            loadRestored(model.directory, in: model)
        }
        announceLocation()
        host?.panelCursorDidChange(self)
    }

    /// Tells the host where the panel is, unless that is where it was told last: a folder
    /// that is merely read again is not a new place, and whoever follows the panels (a quick
    /// view, the history of places) must not take it for one.
    private func announceLocation() {
        let shown = (tab: ObjectIdentifier(model), location: model.directory.locationKey)
        if let announced, announced.tab == shown.tab, announced.location == shown.location { return }
        announced = shown
        host?.panelDidChangeLocation(self)
    }

    /// Reads the folder of a tab that has not shown anything yet (one restored from the last
    /// session). A folder that is gone is replaced by its nearest parent that can be read, as for
    /// the panels on start-up, and not complained about on every visit; only when nothing can be
    /// read at all the error is reported.
    private func loadRestored(_ location: URL, in tab: PanelModel) {
        let parent = (try? kernel.fileSystems.provider(for: location))?.parent(of: location)
        let next = parent.flatMap { $0.isSameLocation(as: location) ? nil : $0 }
        load(location, in: tab, focus: nil, history: .keep, reportFailure: next == nil) { [weak self] succeeded in
            guard let self, !succeeded, let next, !tab.isListed, loads[ObjectIdentifier(tab)] == nil else {
                return
            }
            loadRestored(next, in: tab)
        }
    }

    /// Redraws everything from the active tab.
    func redraw() {
        guard isViewLoaded else { return }
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
        showCursor()
        placeRenameField()
        updatePathBar()
        showQuickFilterBar()
        tabBar.update(
            titles: tabs.tabs.indices.map { DisplayText.clean(tabs.title(at: $0)) },
            paths: tabs.tabs.map { DisplayText.clean(kernel.fileSystems.displayPath($0.directory)) },
            active: tabs.activeIndex)
        volumeButton.setTitle(DisplayText.clean(model.volume?.name ?? model.directory.scheme ?? "/"))
        if let free = model.volume?.freeBytes, let total = model.volume?.totalBytes {
            freeLabel.stringValue = "\(Format.shortSize(free)) of \(Format.shortSize(total)) free"
        } else {
            freeLabel.stringValue = ""
        }
        for tableColumn in tableView.tableColumns {
            let key = FileListColumn(rawValue: tableColumn.identifier.rawValue)?.sortKey
            let image =
                key == model.wantedSort.key
                ? NSImage(named: model.wantedSort.descending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator")
                : nil
            tableView.setIndicatorImage(image, in: tableColumn)
        }
        sortHeader.order = model.wantedSort
        updateStatus()
    }

    func updateStatus() {
        guard isViewLoaded else { return }
        if model.isOpening {
            statusLabel.stringValue = "Reading \(DisplayText.clean(kernel.fileSystems.displayPath(model.directory)))…"
        } else if model.isRefreshing {
            statusLabel.stringValue = Self.statusText(totals(of: model), refreshing: true)
        } else if viewMode == .brief, model.isComplete, model.selectionCount == 0, let item = model.cursorItem {
            // In the Brief view the line tells what the list does not show (spec 03 › Status line).
            statusLabel.stringValue = Self.detailText(for: item)
        } else {
            statusLabel.stringValue = Self.statusText(
                totals(of: model), itemsSoFar: model.isComplete ? nil : model.items.count)
        }
        if let filter = quickFilters[ObjectIdentifier(model)], !filter.text.isEmpty {
            statusLabel.stringValue += "   ⏷ Filter: \(filter.text)"
        }
        // The wheel turns for as long as the folder on screen is not all there.
        showsActivity = isLoading && !model.isComplete
        if showsActivity {
            activityIndicator.startAnimation(nil)
        } else {
            activityIndicator.stopAnimation(nil)
        }
    }

    /// The figures of a tab. The model keeps them as it goes: those of the list come with the
    /// list when that was worked out in the background, those of the marks follow every mark
    /// that is set or taken away, and marking everything or the opposite is arithmetic. So
    /// asking costs nothing here, whatever changed and however long the list is.
    private func totals(of tab: PanelModel) -> PanelModel.Totals {
        tab.totals
    }

    /// Whether the busy indicator in the status line is turning.
    private(set) var showsActivity = false

    private lazy var activityIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        return indicator
    }()

    var statusLineText: String { statusLabel.stringValue }

    /// `5 k / 8 k in 4 / 14 file(s), 0 / 2 dir(s)` (spec 03 › Status line). While a directory
    /// is still arriving, the line says so and counts what has come; while a remembered listing
    /// is read afresh, it says that.
    static func statusText(_ totals: PanelModel.Totals, itemsSoFar: Int? = nil, refreshing: Bool = false) -> String {
        var text =
            "\(Format.kilobytes(totals.selectedBytes)) / \(Format.kilobytes(totals.totalBytes)) in "
            + "\(totals.selectedFiles) / \(totals.totalFiles) file(s)"
        if totals.totalFolders > 0 { text += ", \(totals.selectedFolders) / \(totals.totalFolders) dir(s)" }
        if let itemsSoFar { text = "Loading… \(Format.bytes(Int64(itemsSoFar))) items so far   " + text }
        if refreshing { text = "Refreshing…   " + text }
        return text
    }

    // MARK: PanelHandle

    var isLoading: Bool { loads[ObjectIdentifier(model)] != nil }

    /// True while a reading of the active tab's folder that was put off is still to come.
    var hasPendingReread: Bool { dirty[ObjectIdentifier(model)] != nil }

    func focus() {
        view.window?.makeFirstResponder(listView)
        host?.panelDidBecomeActive(self)
    }

    func show(_ location: URL, focus: String?, history: PanelModel.HistoryEffect, completion: ((Bool) -> Void)?) {
        load(location, in: model, focus: focus, history: history, reportFailure: true, completion: completion)
    }

    /// One reading of a location for a tab: its cancellation, the order the list should come in,
    /// and who is waiting for it to end.
    private final class Load {
        let flag = CancellationFlag()
        /// The order of the tab's list, which the reading follows when it changes under way.
        let order: PanelLoading.OrderBox
        /// Where the reading takes the tab; nil for a reading of the folder the tab shows.
        let destination: URL?
        /// A quiet reading: nothing is announced unless it finds the folder changed.
        let isQuiet: Bool
        /// When the reading was asked for, in the system's uptime.
        let started = ProcessInfo.processInfo.systemUptime
        /// What has to live as long as the reading (the way out of a reading that was taken over).
        var keeps: [AnyObject] = []
        private var completion: ((Bool) -> Void)?

        init(order: ListOrder, destination: URL?, isQuiet: Bool, completion: ((Bool) -> Void)?) {
            self.order = PanelLoading.OrderBox(order)
            self.destination = destination
            self.isQuiet = isQuiet
            self.completion = completion
        }

        /// The reading ended; `succeeded` is false for a failure. Whoever waits is told once.
        func complete(_ succeeded: Bool) {
            let waiting = completion
            completion = nil
            keeps = []
            waiting?(succeeded)
        }

        /// A newer reading overtook this one, or its tab is gone: whoever waits hears of
        /// the failure, after the newer reading is in place.
        func supersede() {
            MainLoop.perform { self.complete(false) }
        }
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A reading of `tab` has come to its end, whichever way: the status line, the host and
    /// whoever waited hear of it, and a change that was put off meanwhile gets its turn.
    /// `changed` is false for a quiet reading that found the folder as the tab shows it.
    private func readingEnded(of tab: PanelModel, _ load: Load, succeeded: Bool, changed: Bool = true) {
        let id = ObjectIdentifier(tab)
        let now = uptime
        lastRead[id] = (now, now - load.started)
        if tab === model {
            updateStatus()
            announceLocation()
        }
        if load.isQuiet, !changed {
            host?.panelActivityDidChange(self)
        } else {
            host?.panelCursorDidChange(self)
        }
        load.complete(succeeded)
        rereadIfDirty(tab)
    }

    /// Makes a change of a tab's list that the model works out from the list as it is
    /// (`PanelModel.prepare`): a fresh reading compared with what is shown, a list that has
    /// grown, another filter. For a long list all of that is done in the background, on all
    /// cores, and the main thread only takes the result over (`PanelModel.apply`, a few
    /// milliseconds at a million entries); a short one is done on the spot. Should the list,
    /// its filter or its order have changed while the work was under way, nothing was done
    /// here and the work starts again from the list as it is now, again in the background.
    ///
    /// `count` is the length of the list that is coming. `isWanted` is asked on the main
    /// thread before the result is taken: when it says no, nothing is changed and `done`
    /// hears nil. The lists that go are let go of by the model, off the main thread.
    ///
    /// `fresh` is the list the change brings, when it brings one. It may turn out not to be
    /// needed (the folder is as it was): then it is let go of, and that too must not happen
    /// here. So one more hold on it is kept until everything that carried it across the
    /// threads is gone, and that last hold is dropped in the background.
    func change(
        _ tab: PanelModel, count: Int = 0, fresh: [FileItem] = [], while isWanted: @escaping () -> Bool = { true },
        by prepare: @escaping (PanelModel.Basis) -> PanelModel.Prepared,
        then done: @escaping (PanelModel.Outcome?) -> Void
    ) {
        MainThread.assert("A panel")
        let basis = tab.basis
        guard max(tab.listedItems.count, count) >= Self.backgroundSortThreshold else {
            done(tab.apply(prepare(basis)))
            return
        }
        Background.compute(
            work: { prepare(basis) },
            then: { [weak self, weak tab] prepared in
                /// Runs after this block and what it holds (the prepared change) have gone.
                func letGoOfFresh() {
                    guard fresh.count >= Self.backgroundSortThreshold else { return }
                    var last: [FileItem]? = fresh
                    MainLoop.perform { Background.release(&last) }
                }
                guard let self, let tab, isWanted() else {
                    letGoOfFresh()
                    return done(nil)
                }
                let outcome = tab.apply(prepared)
                if outcome == .stale {
                    change(tab, count: count, fresh: fresh, while: isWanted, by: prepare, then: done)
                } else {
                    letGoOfFresh()
                    done(outcome)
                }
            })
    }

    /// Forgets what a tab showed before it entered a folder; a long list is freed in the background.
    private func dropSnapshot(of id: ObjectIdentifier) {
        openedFromFilter[id] = nil
        var snapshot = openedFrom.removeValue(forKey: id)
        Background.release(&snapshot)
    }

    /// Takes a tab back to what it showed when `snapshot` was taken, with the quick filter
    /// it had then: the model puts its filter back (`PanelModel.restore`), and the text of
    /// the quick filter, which is kept here, comes back with it.
    private func restore(_ tab: PanelModel, to snapshot: PanelModel.Snapshot, quickFilter: QuickFilter?) {
        let id = ObjectIdentifier(tab)
        // A filtering under way was for the folder that is left again.
        filterJobs[id] = nil
        quickFilters[id] = quickFilter
        tab.restore(snapshot)
        // Text that was typed and had not reached the list when the snapshot was taken.
        if let quickFilter, tab.filter?.title != quickFilter.title {
            quickFilters[id] = quickFilter
            setFilter(quickFilter.combined, of: tab)
        }
    }

    /// A reading that was taken over from the read-ahead is left when this reading is overtaken.
    private func leave(_ joined: ReadAhead.Joined, whenOvertaken load: Load) {
        load.keeps.append(load.flag.onCancel { MainLoop.perform(joined.leave) })
    }

    /// Reads a location in the background and shows it in `tab`, piece by piece when it takes
    /// long. A failure leaves the tab as it was.
    func load(
        _ location: URL, in tab: PanelModel, focus: String?, history: PanelModel.HistoryEffect, reportFailure: Bool,
        completion: ((Bool) -> Void)?
    ) {
        MainThread.assert("A panel")
        guard !isShutDown else {
            if let completion { MainLoop.perform { completion(false) } }
            return
        }
        if showRemembered(
            location, in: tab, focus: focus, history: history, reportFailure: reportFailure, completion: completion)
        {
            return
        }
        // The folder under the cursor may be on its way already, read ahead: then the panel
        // waits for that reading instead of asking the file system a second time.
        let joined = host?.panel(self, joinReadingOf: location, showHidden: tab.showHidden)
        let id = ObjectIdentifier(tab)
        let load = beginLoad(for: tab, movingTo: location, completion: completion)
        let flag = load.flag
        let previousDirectory = tab.directory
        let start: (@escaping (PanelLoading.Piece) -> Void, @escaping (any Error?) -> Void) -> Void
        if let joined {
            leave(joined, whenOvertaken: load)
            start = { [weak self] onPiece, onEnd in
                joined.receive { outcome in
                    // Main thread, when the reading that was taken over has ended.
                    switch outcome {
                    case .failure(let error): onEnd(error)

                    case .success(let whole):
                        guard let self else { return }
                        self.sorted(whole, for: tab) { whole in
                            onPiece(
                                PanelLoading.Piece(
                                    listing: whole.listing, focus: whole.focus, order: whole.order, isFirst: true,
                                    isLast: true))
                            onEnd(nil)
                        }
                    }
                }
            }
        } else {
            start =
                PanelLoading(
                    location: location, showHidden: tab.showHidden, order: load.order, fileSystems: kernel.fileSystems,
                    cache: kernel.listingCache, cancellation: flag
                ).start
        }
        // A directory that does not answer for a while is entered anyway: the panel shows its
        // path, an empty list and a busy indicator, and fills up as the entries arrive. Should
        // the reading fail, the panel goes back to where it was.
        var nothingArrivedYet = true
        MainLoop.after(PanelLoading.emptyOpenDelay) { [weak self] in
            guard let self, nothingArrivedYet, loads[id] === load,
                let provider = try? kernel.fileSystems.provider(for: location)
            else { return }
            if tab.isOpening, let before = openedFrom[id] {
                // The tab was entered already, by a reading this one overtook. That visit showed
                // nothing and is taken back first, so it does not stay in the history as a
                // place the panel has been; the way back remains the one it was.
                restore(tab, to: before, quickFilter: openedFromFilter[id])
            } else {
                openedFrom[id] = tab.snapshot()
                openedFromFilter[id] = quickFilters[id]
            }
            dropQuickFilter(of: tab, unlessIn: location)
            tab.open(
                location, parent: provider.parent(of: location), root: provider.root(of: location), history: history)
        }
        // Pieces and the end are taken in the order they come. A piece that has to be sorted
        // first, in the background, holds back whatever comes after it.
        var behind: [() -> Void] = []
        var isHolding = false
        func inOrder(_ step: @escaping () -> Void) {
            if isHolding { behind.append(step) } else { step() }
        }
        func releaseHeld() {
            while !isHolding, !behind.isEmpty { behind.removeFirst()() }
        }
        func take(_ piece: PanelLoading.Piece) {
            // Main thread. A read that was overtaken by a newer one is dropped.
            guard self.loads[id] === load else { return }
            // The reading follows the order of the list; one piece that was made in the order
            // before is skipped, the next one holds the whole list again (and is in the new order).
            load.order.value = tab.wantedSort
            if piece.order != tab.wantedSort, !piece.isFirst, !piece.isLast { return }
            // The order was changed while this piece was on its way: a long list is put in the
            // new order in the background (the common case, the other direction, is one pass).
            let wanted = tab.wantedSort
            if piece.order != wanted, piece.listing.items.count >= Self.backgroundSortThreshold {
                isHolding = true
                // Entries are there, only not in order yet: the folder is not entered empty meanwhile.
                nothingArrivedYet = false
                Background.compute(
                    work: { () -> PanelLoading.Piece in
                        let old = piece.listing
                        let listing = Listing(
                            directory: old.directory, items: Sorter.resort(old.items, from: piece.order, to: wanted),
                            parent: old.parent,
                            root: old.root, volume: old.volume)
                        return PanelLoading.Piece(
                            listing: listing, focus: piece.focus, order: wanted, isFirst: piece.isFirst,
                            isLast: piece.isLast)
                    },
                    then: { resorted in
                        isHolding = false
                        take(resorted)
                        releaseHeld()
                    })
                return
            }
            nothingArrivedYet = false
            let isLong = piece.listing.items.count >= Self.backgroundSortThreshold
            /// A long list grows in the background: filtering what has come, finding the
            /// marked entries and the cursor's again and counting the totals happen there,
            /// and what comes after this piece waits until the list has taken it.
            func grow() {
                isHolding = true
                self.change(
                    tab, count: piece.listing.items.count, fresh: piece.listing.items,
                    while: { [weak self] in self?.loads[id] === load },
                    by: { PanelModel.prepare($0, extendingTo: piece.listing.items, sortedBy: piece.order) },
                    then: { outcome in
                        isHolding = false
                        if outcome != nil, piece.isLast { tab.finishLoading() }
                        releaseHeld()
                    })
            }
            if piece.isFirst {
                self.dropSnapshot(of: id)
                self.dropQuickFilter(of: tab, unlessIn: piece.listing.directory)
                if isLong {
                    // A folder that was read in one go and is long: its first screens are shown
                    // at once, as if it were still arriving, and the whole list follows from the
                    // background a moment later, so entering it costs the main thread no pass
                    // over the list.
                    let whole = piece.listing
                    let head = Listing(
                        directory: whole.directory, items: Array(whole.items.prefix(PanelLoading.firstPieceLimit)),
                        parent: whole.parent, root: whole.root, volume: whole.volume)
                    tab.show(
                        head, focus: focus ?? piece.focus, history: history, complete: false, presorted: piece.order)
                } else {
                    tab.show(
                        piece.listing, focus: focus ?? piece.focus, history: history, complete: piece.isLast,
                        presorted: piece.order)
                }
                // The panel is in the folder from its first entries on, not only when the last has come.
                if tab === self.model { self.announceLocation() }
                if isLong { grow() }
            } else if isLong || tab.listedItems.count >= Self.backgroundSortThreshold {
                grow()
            } else {
                tab.extend(to: piece.listing.items, sortedBy: piece.order)
                if piece.isLast { tab.finishLoading() }
            }
        }
        func end(_ error: any Error?) {
            guard self.loads[id] === load else { return }
            self.loads[id] = nil
            nothingArrivedYet = false
            if error != nil, tab.isOpening, let before = self.openedFrom[id] {
                // Nothing could be read: back to the folder the panel came from, whichever
                // reading entered the new one, with the quick filter it had there.
                self.restore(tab, to: before, quickFilter: self.openedFromFilter[id])
            }
            self.dropSnapshot(of: id)
            if error != nil, tab.isListed, !tab.isComplete, tab.directory.isSameLocation(as: previousDirectory) {
                // The tab shows part of a directory whose reading was overtaken by this failed
                // attempt: it is read again (once; that reading does not come back here), so it
                // does not stay half-listed.
                self.reload(tab, focus: nil, quietly: false, completion: nil)
            } else {
                // An error in the middle of a listing ends it with what has arrived.
                tab.finishLoading()
            }
            self.readingEnded(of: tab, load, succeeded: error == nil)
            if let error, reportFailure { self.report(error) }
        }
        start({ piece in inOrder { take(piece) } }, { error in inOrder { end(error) } })
    }

    /// Tells the user a folder could not be read, once the code that found out has finished,
    /// from the run loop and after any message that is still on screen (`MainLoop.dialog`): the
    /// alert is modal and runs its own event loop.
    private func report(_ error: any Error) {
        let ui = kernel.ui
        MainLoop.dialog { ui.report(error, title: "The folder cannot be read!") }
    }

    /// Hands on a listing in the order of `tab`. One that is in another order (the order was
    /// changed while it was read) is sorted in the background first, so the main thread only
    /// takes over a finished list; should the order change again meanwhile, once more.
    private func sorted(
        _ whole: PanelLoading.Whole, for tab: PanelModel, then receive: @escaping (PanelLoading.Whole) -> Void
    ) {
        let order = tab.wantedSort
        guard whole.order != order else {
            receive(whole)
            return
        }
        Background.compute(
            work: { () -> PanelLoading.Whole in
                let old = whole.listing
                let listing = Listing(
                    directory: old.directory, items: Sorter.resort(old.items, from: whole.order, to: order),
                    parent: old.parent, root: old.root,
                    volume: old.volume)
                return PanelLoading.Whole(listing: listing, focus: whole.focus, order: order)
            }, then: { [self] resorted in sorted(resorted, for: tab, then: receive) })
    }

    /// Show old, refresh behind: when the listing cache remembers `location`, the tab shows that
    /// listing at once, in place of an empty "Reading…", and the location is read afresh in the
    /// background. The fresh listing is applied with `PanelModel.update(with:)`, which keeps
    /// cursor, selection and calculated folder sizes and changes the list only where it differs.
    /// Until then the list can be used, but the model is not complete, so commands that mean
    /// "everything" wait. If the fresh reading fails, the tab goes back to where it came from,
    /// as after any failed reading, and the remembered listing is dropped.
    ///
    /// Returns false, having done nothing, when nothing recent enough is remembered.
    private func showRemembered(
        _ location: URL, in tab: PanelModel, focus: String?, history: PanelModel.HistoryEffect,
        reportFailure: Bool, completion: ((Bool) -> Void)?
    ) -> Bool {
        let cache = kernel.listingCache
        guard let entry = cache.entry(for: location, showHidden: tab.showHidden) else { return false }
        // Should this very folder be on its way already (read ahead), that reading is the fresh one.
        let joined = host?.panel(self, joinReadingOf: location, showHidden: tab.showHidden)
        let id = ObjectIdentifier(tab)
        // Where a failure leads back to: not an empty folder some reading entered and gave up on.
        let entered = tab.isOpening ? openedFrom[id] : nil
        let quickBefore = entered != nil ? openedFromFilter[id] : quickFilters[id]
        let before = entered ?? tab.snapshot()
        let load = beginLoad(for: tab, movingTo: location, completion: completion)
        if let joined { leave(joined, whenOvertaken: load) }
        let flag = load.flag
        let (showHidden, order, fileSystems) = (tab.showHidden, tab.wantedSort, kernel.fileSystems)
        // The state of this visit; used on the main thread only.
        var isShown = false
        /// The remembered listing is on its way into the list (a long one, from the background).
        var isBeingShown = false
        var hasEnded = false
        /// The fresh listing is there (and perhaps on its way into the list): the remembered
        /// one is of no use any more.
        var freshHasCome = false
        var focusStillWanted = focus

        func present(_ entry: ListingCache.Entry) {
            guard !hasEnded, !freshHasCome, loads[id] === load else { return }
            // Remembered in another order than the list has (now): a long one is sorted in the
            // background, then shown, unless the fresh listing gets there first.
            let wanted = tab.wantedSort
            if entry.order != wanted, entry.listing.items.count >= Self.backgroundSortThreshold {
                Background.compute(
                    work: { cache.entry(for: location, showHidden: showHidden, sortedBy: wanted) },
                    then: { entry in if let entry { present(entry) } })
                return
            }
            dropSnapshot(of: id)
            dropQuickFilter(of: tab, unlessIn: entry.listing.directory)
            func shown() {
                isShown = true
                // An item that is not in the remembered listing may be in the fresh one.
                if tab.cursorItem?.name == focus { focusStillWanted = nil }
                // The panel is in the folder now. (Watching it is set up in the background, so
                // a share that does not answer holds nothing up here.)
                if tab === model { announceLocation() }
            }
            guard entry.listing.items.count >= Self.backgroundSortThreshold else {
                tab.showRemembered(entry.listing, focus: focus, history: history, presorted: entry.order)
                shown()
                return
            }
            // A long one is made ready in the background (the filter over every entry, the
            // index of names the cursor is found by, the totals) and only taken over here;
            // unless the fresh listing gets there first, or the reading ends.
            isBeingShown = true
            let listing = entry.listing
            change(
                tab, count: listing.items.count,
                while: { [weak self] in self?.loads[id] === load && !hasEnded && !freshHasCome },
                by: {
                    PanelModel.prepare(
                        $0, show: listing, focus: focus, history: history, remembered: true, presorted: entry.order)
                },
                then: { outcome in
                    isBeingShown = false
                    if outcome != nil { shown() }
                })
        }
        if entry.order == order {
            present(entry)
        } else {
            Background.compute(
                work: { cache.entry(for: location, showHidden: showHidden, sortedBy: order) },
                then: { entry in if let entry { present(entry) } })
        }

        /// Main thread: the fresh reading has ended.
        func finish(_ outcome: Result<PanelLoading.Whole?, any Error>) {
            guard loads[id] === load else { return }
            func end(_ error: any Error?) {
                loads[id] = nil
                hasEnded = true
                readingEnded(of: tab, load, succeeded: error == nil)
                if let error, reportFailure { report(error) }
            }
            switch outcome {
            case .success(let whole?):
                freshHasCome = true
                if isShown {
                    // The fresh listing is compared with the remembered one, filtered, and the
                    // marks and the cursor found in it, in the background for a long list; in
                    // whatever order the list is by then.
                    let wanted = focusStillWanted
                    change(
                        tab, count: whole.listing.items.count, fresh: whole.listing.items,
                        while: { [weak self] in self?.loads[id] === load },
                        by: { PanelModel.prepare($0, update: whole.listing, focus: wanted, presorted: whole.order) },
                        then: { [self] outcome in
                            guard outcome != nil else { return }
                            dropSnapshot(of: id)
                            end(nil)
                        })
                } else {
                    sorted(whole, for: tab) { [self] whole in
                        guard loads[id] === load else { return }
                        dropSnapshot(of: id)
                        dropQuickFilter(of: tab, unlessIn: whole.listing.directory)
                        guard whole.listing.items.count >= Self.backgroundSortThreshold else {
                            tab.show(
                                whole.listing, focus: focus ?? whole.focus, history: history, presorted: whole.order)
                            return end(nil)
                        }
                        // A long one is entered from the background, like a remembered one.
                        change(
                            tab, count: whole.listing.items.count, fresh: whole.listing.items,
                            while: { [weak self] in self?.loads[id] === load },
                            by: {
                                PanelModel.prepare(
                                    $0, show: whole.listing, focus: focus ?? whole.focus, history: history,
                                    presorted: whole.order)
                            },
                            then: { outcome in
                                guard outcome != nil else { return }
                                end(nil)
                            })
                    }
                }

            case .success(nil):
                // Stopped, which only a newer reading does; that one has taken over.
                break

            case .failure(let error):
                cache.forget(location)
                // (A remembered listing that was still on its way into the list has taken the
                // quick filter off the folder the tab stays in: that comes back as well.)
                if isShown || isBeingShown || tab.isOpening { restore(tab, to: before, quickFilter: quickBefore) }
                dropSnapshot(of: id)
                end(error)
                // The folder the tab is back in was itself still arriving when it was left (and
                // is read again once; that reading does not come back here).
                if tab.isListed, !tab.isComplete { reload(tab, focus: nil, quietly: false, completion: nil) }
            }
        }
        if let joined {
            joined.receive { outcome in finish(outcome.map { Optional($0) }) }
        } else {
            Background.storage(
                "list", at: location,
                work: { () -> Result<PanelLoading.Whole?, any Error> in
                    // Overtaken while it waited for its turn: the file system is not asked.
                    guard !flag.isCancelled else { return .success(nil) }
                    return Result {
                        try PanelLoading.readWhole(
                            location, showHidden: showHidden, order: order, fileSystems: fileSystems,
                            cache: cache, cancellation: flag)
                    }
                }, then: { finish($0) })
        }
        return true
    }

    func reload(focus: String?, quietly: Bool, completion: (() -> Void)?) {
        reload(model, focus: focus, quietly: quietly, completion: completion)
    }

    /// The folder of the active tab was reported changed at `time` (of the system's uptime),
    /// perhaps a while ago: it is read again quietly, unless a reading that began after the
    /// change is under way already.
    func reloadForChange(at time: TimeInterval) {
        reload(model, focus: nil, quietly: true, changedAt: time, completion: nil)
    }

    /// How long a quiet reading of a tab's folder has to wait still: after a reading there is
    /// a pause of `minimumRereadInterval`, and of twice the time that reading took if that is
    /// longer. Nil when it may start now.
    private func waitBeforeQuietRead(of id: ObjectIdentifier) -> TimeInterval? {
        guard let last = lastRead[id] else { return nil }
        let wait = last.ended + max(Self.minimumRereadInterval, 2 * last.cost) - uptime
        return wait > 0 ? wait : nil
    }

    /// Looks at a tab again when the pause after its last reading is over.
    private func scheduleReread(of tab: PanelModel, after wait: TimeInterval) {
        let id = ObjectIdentifier(tab)
        guard rereadTimers[id] == nil else { return }
        rereadTimers[id] = MainLoop.after(wait) { [weak self, weak tab] in
            guard let self else { return }
            rereadTimers[id] = nil
            if let tab, tabs.tabs.contains(where: { $0 === tab }) { rereadIfDirty(tab) }
        }
    }

    /// Notes that the folder of a tab may have changed in a way no reading has seen: the one
    /// it shows, and the one a reading under way is taking it to.
    private func noteChange(in tab: PanelModel) {
        let id = ObjectIdentifier(tab)
        dirty[id, default: []].insert(tab.directory.locationKey)
        if let destination = loads[id]?.destination { dirty[id]?.insert(destination.locationKey) }
    }

    private func flushWaitingCompletions(of id: ObjectIdentifier) {
        guard let waiting = waitingCompletions.removeValue(forKey: id) else { return }
        waiting.forEach { $0() }
    }

    /// `markDirty`: a quiet reload that is turned away because the tab is being read or renamed,
    /// or was read a moment ago, is made up for when that is over (the folder may have changed
    /// since the reading began). `changedAt`: when the change that asks for this was noticed,
    /// if not now. `completion` is called when the folder has been read, also when that
    /// happens later or is another reading's doing.
    private func reload(
        _ tab: PanelModel, focus: String?, quietly: Bool, markDirty: Bool = true, changedAt: TimeInterval? = nil,
        completion: (() -> Void)?
    ) {
        MainThread.assert("A panel")
        guard !isShutDown else {
            if let completion { MainLoop.perform(completion) }
            return
        }
        let id = ObjectIdentifier(tab)
        func later() {
            if let completion { waitingCompletions[id, default: []].append(completion) }
        }
        if quietly {
            // A quiet reload must not disturb a rename in progress, and a directory that is being
            // read right now is fresh anyway, unless it changed after that reading began.
            if renameField != nil || loads[id] != nil {
                let isCovered =
                    renameField == nil
                    && (loads[id].map { load in changedAt.map { $0 < load.started } ?? false } ?? false)
                if markDirty, !isCovered { noteChange(in: tab) }
                // Nothing is going to end that could tell whoever waits.
                if loads[id] == nil, dirty[id] == nil { completion?() } else { later() }
                return
            }
            // Read a moment ago: once more when the pause is over, however many changes are reported until then.
            if tab.isListed, let wait = waitBeforeQuietRead(of: id) {
                guard markDirty else {
                    completion?()
                    return
                }
                noteChange(in: tab)
                later()
                scheduleReread(of: tab, after: wait)
                return
            }
        } else if let pending = loads[id], let destination = pending.destination,
            !destination.isSameLocation(as: tab.directory)
        {
            // The tab is on its way to another folder. That reading is not thrown over for one of
            // the folder being left; should it fail and the tab stay, the folder is read then.
            dirty[id, default: []].insert(tab.directory.locationKey)
            later()
            return
        }
        guard tab.isListed else {
            load(tab.directory, in: tab, focus: focus, history: .keep, reportFailure: !quietly) { _ in
                completion?()
            }
            return
        }
        let reading = beginLoad(for: tab, movingTo: nil, quiet: quietly) { _ in completion?() }
        let flag = reading.flag
        let (directory, showHidden, order, fileSystems, cache) = (
            tab.directory, tab.showHidden, tab.wantedSort, kernel.fileSystems, kernel.listingCache
        )
        Background.storage(
            "list", at: directory,
            work: { () -> Result<PanelLoading.Whole?, any Error> in
                guard !flag.isCancelled else { return .success(nil) }
                // A folder that vanished is replaced by its nearest readable parent. The listing is
                // sorted here and, like every complete one, handed to the cache.
                let outcome = Result {
                    try PanelLoading.readWhole(
                        directory, showHidden: showHidden, order: order, fileSystems: fileSystems, cache: cache,
                        climbing: true, cancellation: flag)
                }
                let whole = (try? outcome.get()) ?? nil
                // What is remembered of a folder that is gone or cannot be read is of no use.
                if !flag.isCancelled, !(whole?.listing.directory.isSameLocation(as: directory) ?? false) {
                    cache.forget(directory)
                }
                return outcome
            },
            then: { [self] outcome in
                guard loads[id] === reading else { return }
                guard case .success(let read) = outcome, let whole = read else {
                    // Nothing could be read: what the tab shows is all there will be.
                    loads[id] = nil
                    tab.finishLoading()
                    readingEnded(of: tab, reading, succeeded: true, changed: false)
                    // Whoever asked for the folder to be read again hears why it was not.
                    if case .failure(let error) = outcome, !quietly, !flag.isCancelled { report(error) }
                    return
                }
                // The folder was replaced by a parent: what was calculated for it is of no use.
                if !whole.listing.directory.isSameLocation(as: directory) { cancelSizeCalculations(of: tab) }
                dropQuickFilter(of: tab, unlessIn: whole.listing.directory)
                // Everything that grows with the list is done in the background for a long one:
                // bringing it into the tab's order (which may have changed while it was read),
                // comparing it with what the tab shows, filtering, finding the marked entries
                // again. The main thread takes the result, or nothing at all when the folder is
                // as it was.
                change(
                    tab, count: whole.listing.items.count, fresh: whole.listing.items,
                    while: { [weak self] in self?.loads[id] === reading },
                    by: { PanelModel.prepare($0, update: whole.listing, focus: focus, presorted: whole.order) },
                    then: { [self] outcome in
                        guard let outcome, loads[id] === reading else { return }
                        loads[id] = nil
                        // A folder that is merely read again is no new place; one that was replaced by
                        // its parent, or was never announced, is (`announceLocation` knows).
                        readingEnded(of: tab, reading, succeeded: true, changed: outcome == .changed)
                    })
            })
    }

    /// Reads a tab once more if its folder changed while it was read or renamed, or too soon
    /// after it was read; whoever waits for that is told when there is nothing left to read.
    func rereadIfDirty(_ tab: PanelModel? = nil) {
        let tab = tab ?? model
        let id = ObjectIdentifier(tab)
        guard let locations = dirty[id] else {
            if loads[id] == nil { flushWaitingCompletions(of: id) }
            return
        }
        guard loads[id] == nil else { return }
        guard locations.contains(tab.directory.locationKey) else {
            // The tab has left the folder the change was in.
            dirty[id] = nil
            flushWaitingCompletions(of: id)
            return
        }
        guard renameField == nil, !commands.isBlocked() else { return }
        if let wait = waitBeforeQuietRead(of: id) {
            scheduleReread(of: tab, after: wait)
            return
        }
        reload(tab, focus: nil, quietly: true, completion: nil)
    }

    /// Abandons every read and calculation in progress, for good: the window goes away.
    /// Whoever waits for one of them hears that it came to nothing.
    func cancelLoading() {
        isShutDown = true
        let abandoned = Array(loads.values)
        abandoned.forEach { $0.flag.cancel() }
        sizeCalculations.values.forEach { $0.cancel() }
        loads = [:]
        sizeCalculations = [:]
        rereadTimers.values.forEach { $0() }
        rereadTimers = [:]
        dirty = [:]
        typeFind?.cancel()
        volumeAsking.values.forEach { $0.cancel() }
        (volumeAsking, volumeAskAgain) = ([:], [])
        abandoned.forEach { $0.supersede() }
        for id in Array(waitingCompletions.keys) { flushWaitingCompletions(of: id) }
    }

    private func cancelSizeCalculations(of tab: PanelModel) {
        sizeCalculations.removeValue(forKey: ObjectIdentifier(tab))?.cancel()
    }

    /// Starts a reading for `tab`, which overtakes the one before. Calculations of folder sizes
    /// go on unless the tab moves to another folder (`location` is not where it is).
    private func beginLoad(
        for tab: PanelModel, movingTo location: URL?, quiet: Bool = false, completion: ((Bool) -> Void)?
    ) -> Load {
        let id = ObjectIdentifier(tab)
        if let overtaken = loads[id] {
            overtaken.flag.cancel()
            overtaken.supersede()
        }
        if let location, !location.isSameLocation(as: tab.directory) { cancelSizeCalculations(of: tab) }
        // Whatever this reading finds is newer than anything that was missed before.
        dirty[id] = nil
        rereadTimers.removeValue(forKey: id)?()
        let load = Load(order: tab.wantedSort, destination: location, isQuiet: quiet, completion: completion)
        loads[id] = load
        if quiet {
            host?.panelActivityDidChange(self)
        } else {
            host?.panelCursorDidChange(self)
        }
        return load
    }

    // MARK: Volume list

    func showVolumeList() {
        focus()
        volumeButton.performClick(nil)
    }

    /// The list is filled from the places every file system offers. They are asked for in the
    /// background (a file system may have to look at its volumes first); the menu shows the
    /// ones that are known, and takes the others in when they arrive while it is open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            fillHeaderMenu()
            return
        }
        guard menu === volumeButton.menu else { return }
        fillVolumeMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === volumeButton.menu { volumeMenuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === volumeButton.menu { volumeMenuIsOpen = false }
    }

    /// More places are known than when the volume list was last filled.
    func placesDidChange() {
        if volumeMenuIsOpen, let menu = volumeButton.menu { fillVolumeMenu(menu) }
        updateEjectButton()
    }

    /// Shows the eject button of the path bar while the folder is on a drive that can be ejected.
    func updateEjectButton() {
        pathBar.ejectableVolumeName = host?.ejectableVolume(containing: model.directory)?.name
    }

    private func fillVolumeMenu(_ menu: NSMenu) {
        let title = menu.items.first?.title ?? ""
        menu.removeAllItems()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        var lastKind: Place.Kind?
        for place in host?.placesForVolumeList(of: self) ?? [] {
            let isVolume = place.kind == .internalDisk || place.kind == .externalDisk
            if let lastKind, isVolume != (lastKind == .internalDisk || lastKind == .externalDisk) {
                menu.addItem(.separator())
            }
            lastKind = place.kind
            let item = menu.addItem(
                withTitle: DisplayText.clean(place.name), action: #selector(placeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = place.url
            let symbol: String
            switch place.kind {
            case .home: symbol = "house"
            case .folder: symbol = "folder"
            case .internalDisk: symbol = "internaldrive"
            case .externalDisk: symbol = "externaldrive"
            }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    @objc private func placeChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { performFocused(.changeDirectory, .location(url)) }
    }

    // MARK: What the list itself does (called by the shell's commands)

    /// Rows that fit in the list, for Page Up and Page Down.
    var pageSize: Int {
        showsGrid ? gridView.geometry.pageSize : max(1, tableView.rows(in: tableView.visibleRect).length - 1)
    }

    /// Space: toggles the item; on a newly selected folder also calculates its size, on all
    /// cores, in the background.
    func toggleSelectionWithSize() {
        guard let item = model.cursorItem else { return }
        let tab = model
        tab.toggleSelection(row: tab.cursor)
        guard item.isFolder, tab.isSelected(item), item.computedSize == nil,
            let provider = try? kernel.fileSystems.provider(for: item.url)
        else { return }
        let directory = tab.directory
        let flag = sizeCalculations[ObjectIdentifier(tab)] ?? CancellationFlag()
        sizeCalculations[ObjectIdentifier(tab)] = flag
        // In the lane of the folder that is measured: a server that does not answer holds up
        // the measuring of that folder, and nothing else.
        Background.storage(
            "size", at: item.url, work: { provider.totalSize(of: item.url, cancellation: flag) },
            then: { [weak self] size in
                guard !flag.isCancelled, tab.directory.isSameLocation(as: directory) else { return }
                self?.sizeArrived(size, forName: item.name, in: tab, directory: directory, flag: flag)
            })
    }

    private func sizeArrived(
        _ size: Int64, forName name: String, in tab: PanelModel, directory: URL, flag: CancellationFlag
    ) {
        let id = ObjectIdentifier(tab)
        if arrivedSizes[id] != nil {
            arrivedSizes[id]?.sizes.append((name: name, size: size))
            return
        }
        arrivedSizes[id] = (directory, flag, [(name: name, size: size)])
        MainLoop.perform { [weak self, weak tab] in
            guard let self, let pending = arrivedSizes.removeValue(forKey: id), let tab, !pending.flag.isCancelled,
                tab.directory.isSameLocation(as: pending.directory)
            else { return }
            guard tab.listedItems.count >= Self.backgroundSortThreshold else {
                return tab.setComputedSizes(pending.sizes)
            }
            // A long list is shared with whoever holds it besides the tab (the listing cache,
            // a snapshot), and writing a size into it copies it once: that copy is made in the
            // background, and the main thread only puts it in the list's place.
            let (sizes, flag, directory) = (pending.sizes, pending.flag, pending.directory)
            change(
                tab, while: { [weak tab] in !flag.isCancelled && tab?.directory.isSameLocation(as: directory) == true },
                by: { PanelModel.prepare($0, computedSizes: sizes) }, then: { _ in })
        }
    }

    func toggleSelectionAndMove(_ delta: Int) {
        model.toggleSelection(row: model.cursor)
        model.moveCursor(to: model.cursor + delta)
    }

    // MARK: Mouse and keyboard

    @objc func rowDoubleClicked() {
        if tableView.clickedRow >= 0 { commands.perform(.open) }
    }

    /// Marking with the mouse: Cmd+click toggles an item, Shift+click selects the range from
    /// the cursor (spec 05 › Mouse selection modes, the Mac's own conventions).
    func handleClick(row: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Marking is refused while a job runs, like the other commands that change what a job
        // may be working on; a plain click only moves the cursor, as the keys do.
        if modifiers.contains(.command) {
            guard !commands.isBlocked() else { return true }
            model.toggleSelection(row: row)
        } else if modifiers.contains(.shift) {
            guard !commands.isBlocked() else { return true }
            model.setSelected(true, rows: min(row, model.cursor)...max(row, model.cursor))
        } else {
            return false
        }
        model.moveCursor(to: row)
        return true
    }

    func didBecomeFirstResponder() {
        host?.panelDidBecomeActive(self)
    }

    /// Every key is looked up in the key bindings; a key that is bound to nothing goes on to
    /// the table, which uses letters to find a file by typing.
    ///
    /// Two keys are the list's own. Esc takes a quick filter away (it cannot be bound, and it
    /// means nothing else here). And in the Brief and Thumbnails views ← and →, as long as
    /// they have their usual meaning of first and last entry, step sideways through the grid
    /// instead (spec 03 › Brief).
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, quickFilters[ObjectIdentifier(model)] != nil {
            removeQuickFilter()
            return true
        }
        guard var command = kernel.keyBindings.command(for: event) else { return false }
        if showsGrid, KeyModifiers(event.modifierFlags).isEmpty {
            if event.keyCode == 123, command == .cursorToFirstEntry { command = PanelShellCommands.cursorLeft }
            if event.keyCode == 124, command == .cursorToLastEntry { command = PanelShellCommands.cursorRight }
        }
        commands.perform(command)
        return true
    }

    func contextMenu(forRow row: Int) -> NSMenu? {
        if row >= 0 { model.moveCursor(to: row) }
        let onItem = row >= 0 && model.item(atRow: row) != nil
        return MenuBuilder.menu("", kernel.menus.contextMenu(onItem: onItem), commands: commands, keys: nil)
    }

    // MARK: In-place rename (spec 07 › In-place rename)

    /// Whether a click is a second, unhurried click on the item under the cursor, which starts
    /// renaming as in Finder. `wasFocused`: the list had the keyboard before the click, so a
    /// click that only brings the panel to the front renames nothing.
    func isRenameClick(row: Int, event: NSEvent, wasFocused: Bool) -> Bool {
        cancelPendingRename()
        return wasFocused && isActive && event.clickCount == 1 && !isRenaming && row == model.cursor
            && model.item(atRow: row) != nil
            && event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control])
    }

    /// Starts renaming once it is clear that the click was not the first half of a double
    /// click, unless the cursor has moved on by then.
    func scheduleRename(row: Int, after delay: TimeInterval = NSEvent.doubleClickInterval) {
        let tab = model
        let name = tab.item(atRow: row)?.name
        // From the run loop (`MainLoop`), like everything that ends in a command.
        pendingRename = MainLoop.after(delay) { [weak self] in
            guard let self else { return }
            pendingRename = nil
            guard model === tab, tab.cursor == row, tab.cursorItem?.name == name, isActive else { return }
            // Refused wherever the Rename command is (a read-only file system, a running job).
            if commands.isEnabled(.renameOnly) { commands.perform(.editNameInPlace) }
        }
    }

    func cancelPendingRename() {
        pendingRename?()
        pendingRename = nil
    }

    /// The row whose name is being edited; the list leaves its name out while the box is
    /// there, so the old name cannot show through or be drawn over the new one.
    private(set) var renamingRow: Int?

    private func redrawName(ofRow row: Int) {
        if showsGrid {
            gridView.setNeedsDisplay(gridView.bounds)
        } else if row < tableView.numberOfRows {
            tableView.reloadData(
                forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
    }

    func beginRename() {
        guard renameField == nil, let item = model.cursorItem else { return }
        let row = model.cursor
        renamingRow = row
        renaming = (ObjectIdentifier(model), model.directory.locationKey, item.name)
        redrawName(ofRow: row)
        let field = NSTextField(string: item.name)
        if showsGrid { gridView.scrollRowToVisible(row) } else { tableView.scrollRowToVisible(row) }
        field.frame = renameFrame(ofRow: row)
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.focusRingType = .none
        // The box covers the name it replaces: opaque, and above the rows, which the list
        // draws again (and would otherwise draw over it) whenever the selection changes.
        field.isBezeled = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.wantsLayer = true
        field.layer?.zPosition = 100
        listView.addSubview(field)
        renameField = field
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Where the box for the name of a row stands in the list that is on screen.
    private func renameFrame(ofRow row: Int) -> NSRect {
        if showsGrid { return gridView.nameFrame(ofRow: row) }
        let frame = tableView.rect(ofRow: row).intersection(
            tableView.rect(ofColumn: 0).union(tableView.rect(ofColumn: 1)))
        return frame.insetBy(dx: 20, dy: 0).offsetBy(dx: 10, dy: 0)
    }

    /// True while a name is being edited in place.
    var isRenaming: Bool { renameField != nil }

    /// Before the list is drawn again: the editor stays when its item is still in the list of
    /// the tab and folder it was opened in (the list was sorted, read again, got another
    /// volume figure), and follows the item to its row. It goes away, and what was typed with
    /// it, only when the item is gone or the panel shows something else.
    private func keepRenameIfItemRemains() {
        guard renameField != nil, let renaming else { return }
        guard renaming.tab == ObjectIdentifier(model), renaming.location == model.directory.locationKey,
            let row = model.row(ofName: renaming.name)
        else {
            cancelRename(restoringKeyboard: true)
            return
        }
        renamingRow = row
    }

    /// After the list was drawn again: the box stands where its row is now.
    private func placeRenameField() {
        guard let field = renameField, let row = renamingRow else { return }
        // A list that was taken anew has let go of the box with its other views.
        if field.superview !== listView { listView.addSubview(field) }
        let frame = renameFrame(ofRow: row)
        if field.frame != frame { field.frame = frame }
    }

    /// Takes the editor away. `restoringKeyboard`: the program does this, not the user, so the
    /// keyboard goes back to the list if the box had it (it would otherwise be left with the
    /// window, where keys only beep).
    private func cancelRename(restoringKeyboard: Bool = false) {
        guard let field = renameField else { return }
        let hadKeyboard = field.currentEditor().map { view.window?.firstResponder === $0 } ?? false
        renameField = nil
        renaming = nil
        field.removeFromSuperview()
        if let row = renamingRow {
            renamingRow = nil
            redrawName(ofRow: row)
        }
        // A change of the folder that was turned away while the box was open is picked up now,
        // after whatever ended the rename (the Rename command, say) has had its turn.
        if dirty[ObjectIdentifier(model)] != nil {
            MainLoop.perform { [weak self] in self?.rereadIfDirty() }
        }
        if restoringKeyboard, hadKeyboard { view.window?.makeFirstResponder(listView) }
    }

    func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let newName = control.stringValue
            cancelRename()
            focus()
            // The rename itself is the Rename command with the new name as its argument.
            commands.perform(.renameOnly, .text(newName))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            view.window?.makeFirstResponder(listView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_: Notification) {
        // A click outside the box cancels.
        cancelRename()
    }

    /// `win  ini  34 10/11/2026 01:19 rw-r--r--`: the item under the cursor, as the status line
    /// of the Brief view shows it (spec 03 › Status line).
    static func detailText(for item: FileItem) -> String {
        let name = DisplayText.clean(item.isFolder ? "[\(item.name)]" : item.baseName)
        return [
            name, DisplayText.clean(item.ext), FileListColumn.size.text(for: item), FileListColumn.date.text(for: item),
            FileListColumn.attr.text(for: item)
        ]
        .filter { !$0.isEmpty }.joined(separator: "  ")
    }
}
