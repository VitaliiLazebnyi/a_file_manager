import AFMContracts
import AFMKernel
import AppKit

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
/// there at once and read afresh behind (`PanelRememberedVisit`); every reading that reaches its
/// end is handed to the cache on the background thread that made it. The cache is the one thing
/// here that is shared between the main thread and the readers, and it is safe on any thread.
///
/// **Views.** The Full view is a table; Brief and Thumbnails are drawn by `FileGridView`
/// (spec 03 › View types). Only one of them is on screen. Cursor, marking, keys, menus, the
/// in-place editor and drag and drop are handled here, once, for all of them; the parts that
/// differ by view are in the extensions of this class.
///
/// **Lifetimes.** The panel holds the kernel: the shell owns both, and nothing the kernel holds
/// holds a panel. Work in the background holds the panel weakly, so a panel that goes away
/// while a reading is out is not kept alive by it.
internal final class PanelViewController: NSViewController, PanelHandle, PanelOverlayHost, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate
{
    /// Lists from this length on are put in a new order, filtered and compared in the
    /// background (as with the sort commands).
    nonisolated internal static let backgroundSortThreshold = 20_000
    /// The least time between the end of one reading of a folder and the start of a quiet
    /// re-reading; twice the cost of the last reading when that is more.
    internal static let minimumRereadInterval: TimeInterval = 0.5

    /// The panel's folder tabs.
    internal let tabs: PanelTabs
    /// The kernel whose commands, file systems and settings the panel uses.
    internal let kernel: Kernel
    /// Who is told what the panel does.
    internal weak var host: (any PanelHost)?

    // The parts on screen.

    /// The list of the Full view.
    internal let tableView = FileTableView()
    /// The list of the Brief and Thumbnails views.
    internal let gridView = FileGridView()
    /// The header of sort buttons above the grid.
    internal let sortHeader = SortHeaderView()
    /// The drive button of the drive line, with the volume list as its menu.
    internal let volumeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The free space of the volume, beside the drive button.
    internal let freeLabel = NSTextField(labelWithString: "")
    /// The folder tabs.
    internal let tabBar = TabBarView()
    /// The current-directory bar.
    internal let pathBar = PathBarView()
    /// The status line.
    internal let statusLabel = NSTextField(labelWithString: "")
    /// The menu of the column header: the views and the columns to show.
    internal let headerMenu = NSMenu()
    /// The field of the quick filter.
    internal let quickFilterBar = QuickFilterBar()
    /// The scroll view of the table.
    internal let tableScroll = NSScrollView()
    /// The grid with its header.
    internal let gridBox = NSStackView()
    /// The busy indicator of the status line.
    internal let activityIndicator = NSProgressIndicator()
    /// The place of the file list, whichever view shows it; an overlay covers it.
    internal var listArea: NSView?

    // The panel's state.

    /// The user's options for the lists; set by the coordinator.
    internal var settings = PanelSettings() {
        didSet {
            rowColor = nil
            if isViewLoaded {
                redraw()
            }
        }
    }
    /// The layout of the list (spec 03 › View types).
    internal var viewMode = PanelViewMode.full {
        didSet {
            guard viewMode != oldValue else {
                return
            }
            applyViewMode()
            onViewStateChanged?()
        }
    }
    /// The plugin columns of the Full view, by id, after the standard ones.
    internal var extraColumns: [String] = [] {
        didSet {
            guard extraColumns != oldValue else {
                return
            }
            rebuildExtraColumns()
            onViewStateChanged?()
        }
    }
    /// A view shown in place of the file list (`PanelOverlayHost`).
    internal var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let overlay, let listArea, isViewLoaded else {
                return
            }
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
    /// Whether the panel is the source; only its cursor bar is drawn.
    internal var isActive = false {
        didSet {
            pathBar.isActive = isActive
            tableView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
            // Only the cursor bar looks different.
            gridView.redraw(row: model.cursor)
        }
    }
    /// The widths of the columns of the Full view as they were last seen, by identifier.
    internal var columnWidths: [String: Double] = [:]
    /// Called when the view, the columns or their widths changed, so they can be remembered.
    internal var onViewStateChanged: (() -> Void)?
    /// The quick filter of each tab that has one.
    internal var quickFilters: [ObjectIdentifier: QuickFilter] = [:]
    /// The texts of the plugin columns, for the folder on screen.
    internal let columnValues = ColumnValueStore()
    /// The pictures of the Thumbnails view, for the folder on screen.
    internal let thumbnails = ThumbnailStore(source: QuickLookThumbnails())
    /// The tab and folder the two stores above hold values for.
    internal var storedLocation: String?
    /// The tab the list currently shows; differs from `model` for a moment after a tab switch.
    internal weak var shownTab: PanelModel?
    /// Set while the table is updated from the model, so the cursor is not read back.
    internal var syncing = false
    /// The next redraw takes the whole list anew instead of bringing the rows up to date.
    internal var needsFullReload = true
    /// The item the cursor was shown on last: the view scrolls to the cursor when this changes.
    internal var shownCursor: (tab: ObjectIdentifier, name: String?)?
    /// The row the cursor was shown on last.
    internal var shownCursorRow: Int?
    /// Whether the visible cells of the grid were last drawn marked, by row; reset whenever the
    /// grid shows other rows.
    internal var gridMarks: [Int: Bool] = [:]
    /// The colour of the row whose cells were last asked for.
    internal var rowColor: PanelRowColor?
    /// Whether the busy indicator in the status line is turning.
    internal var showsActivity = false
    /// The tab and folder the host was last told the panel shows.
    internal var announced: (tab: ObjectIdentifier, location: String)?

    // Reading.

    /// One running read per tab; starting another cancels the one before.
    internal var loads: [ObjectIdentifier: PanelLoad] = [:]
    /// What a tab showed before a slow reading entered another folder, empty (`PanelModel.open`),
    /// for as long as that reading has delivered nothing.
    ///
    /// It belongs to the tab, not to a reading: a reading that overtakes the one that opened the
    /// folder still goes back to this if it fails, instead of to the empty folder.
    internal var openedFrom: [ObjectIdentifier: PanelModel.Snapshot] = [:]
    /// The quick filter the tab had when that snapshot was taken: it comes back with it.
    internal var openedFromFilter: [ObjectIdentifier: QuickFilter] = [:]
    /// Tabs whose folder changed while a reading or a rename was under way, or too soon after the
    /// last reading: read once more when that is over, so the change is not lost.
    ///
    /// The value is the folders (`URL.locationKey`) the change may have been in: the one the tab
    /// showed and the one it was on its way to. A tab that ends up in neither has nothing to make
    /// up for.
    internal var dirty: [ObjectIdentifier: Set<String>] = [:]
    /// Who waits for a reload that was put off, per tab; told when the reading that makes up
    /// for it has ended.
    internal var waitingCompletions: [ObjectIdentifier: [() -> Void]] = [:]
    /// When each tab's folder was last read to its end (in the system's uptime), and how long
    /// that took from the request to the list on screen.
    internal var lastRead: [ObjectIdentifier: (ended: TimeInterval, cost: TimeInterval)] = [:]
    /// The timers of the readings that were put off, per tab, as the functions that stop them.
    internal var rereadTimers: [ObjectIdentifier: () -> Void] = [:]
    /// Set when the panel was shut down: nothing is read any more.
    internal var isShutDown = false

    // Calculations.

    /// Folder-size calculations started with Space, per tab; cancelled when the tab moves on to
    /// another folder (a reading of the same folder keeps them).
    internal var sizeCalculations: [ObjectIdentifier: CancellationFlag] = [:]
    /// Sizes that came in during one turn of the main loop, per tab.
    internal var arrivedSizes: [ObjectIdentifier: PanelSizeArrivals] = [:]
    /// The tabs whose volume is being asked about: one question at a time per tab, however
    /// often the figures change and however long the file system takes to answer.
    internal var volumeAsking: [ObjectIdentifier: CancellationFlag] = [:]
    /// The tabs that have to be asked about again when the answer is there.
    internal var volumeAskAgain: Set<ObjectIdentifier> = []
    /// Whether the volume list is open, so places that arrive meanwhile are added to it.
    internal var volumeMenuIsOpen = false

    // Typing and filtering.

    /// Typing in the quick filter field waits a moment for more before the list is filtered:
    /// the function that stops the wait.
    internal var pendingQuickFilter: (() -> Void)?
    /// The text waiting in `pendingQuickFilter`, with the tab it was typed in.
    internal var pendingQuickFilterTyping: (tab: PanelModel, text: String)?
    /// The filtering of a long list that runs in the background, per tab, by number; only the
    /// latest one of a tab is taken over, and removing the entry cancels it.
    internal var filterJobs: [ObjectIdentifier: Int] = [:]
    /// The number of the last filtering started.
    internal var filterJobCount = 0
    /// Finding a file by typing: what was typed.
    internal var typeSelect = TypeSelect()
    /// The search of a long list under way, for finding by typing.
    internal var typeFind: CancellationFlag?

    // Renaming and dragging.

    /// The in-place name editor, while it is open.
    internal var renameField: NSTextField?
    /// The item whose name is being edited.
    internal var renaming: PanelRenameTarget?
    /// The rename that follows a click on the item the cursor is already on, waiting for the
    /// double-click time to pass: the function that stops the wait.
    internal var pendingRename: (() -> Void)?
    /// The row whose name is being edited; the list leaves its name out while the box is
    /// there, so the old name cannot show through or be drawn over the new one.
    internal var renamingRow: Int?
    /// What the drag that starts in the table puts on the pasteboard, between the table asking
    /// for the grabbed row and the drag beginning.
    internal var pendingDragItems: [NSPasteboardItem] = []

    /// A panel showing `tabs`, working with `kernel`.
    ///
    /// Its view is made when it is first shown.
    internal init(tabs: PanelTabs, kernel: Kernel) {
        self.tabs = tabs
        self.kernel = kernel
        super.init(nibName: nil, bundle: nil)
        tabs.onChange = { [weak self] in self?.tabsChanged() }
        observeModels()
        // Both are posted on the main thread; the center forgets the panel when it goes.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(volumeInfoChanged(_:)),
            name: FileSystemRegistry.volumeInfoDidChange,
            object: nil
        )
        center.addObserver(self, selector: #selector(iconsArrived(_:)), name: IconStore.didArrive, object: nil)
        // Where the panel starts is known to everybody; what is announced is where it goes from there.
        announced = (ObjectIdentifier(tabs.active), tabs.active.directory.locationKey)
    }

    /// Not made from an archive.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// Builds the panel: drive line, tabs, path bar, the lists, the quick filter field and the
    /// status line, one below the other.
    override internal func loadView() {
        let driveLine = makeDriveLine()
        connectBars()
        setUpTable()
        let list = makeListArea()
        listArea = list
        quickFilterBar.isHidden = true
        quickFilterBar.onChange = { [weak self] text in self?.quickFilterEdited(text) }
        quickFilterBar.onCancel = { [weak self] in self?.removeQuickFilter() }
        quickFilterBar.onReturn = { [weak self] in self?.leaveQuickFilterField() }
        columnValues.onArrival = { [weak self] names in self?.columnValuesArrived(for: names) }
        thumbnails.onArrival = { [weak self] name in self?.thumbnailArrived(for: name) }
        let stack = NSStackView(views: [driveLine, tabBar, pathBar, list, quickFilterBar, makeStatusLine()])
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

    deinit {
        // Nothing to release: the notification center forgets the panel by itself.
    }
}
