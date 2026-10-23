import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The Directory Tree window (spec 12 › Directory Tree dialog): the folders of one volume as
/// an outline, with quick search by typing; Enter shows the chosen folder in the source panel.
///
/// **Threading.** The window and its `DirectoryTree` belong to the main thread. Folders are
/// read and sorted by a `TreeScanner` on a background queue, which hands its results over in
/// batches, together with the nodes for each folder already made: the main thread only links
/// them into the tree, for a bounded time per turn (`turnBudget`), so that a disk with millions
/// of folders never holds the window up. A cached tree is read and built in the background
/// and handed over whole, and the disks that offer roots are asked in the background too.
/// Every hand-over carries the number of the load it belongs to, so results of a load that
/// was replaced or cancelled are dropped.
///
/// Closing the window does not stop a scan that has begun: it goes on in the background, is
/// stored in the cache when it ends and gives up after `hiddenScanLimit`; the tree is then
/// released, since the cache holds it. Aborting with Esc stores what was read, marked as
/// incomplete.
internal final class DirectoryTreeWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource,
    NSOutlineViewDelegate,
    NSTextFieldDelegate
{
    /// How many nodes are linked into the tree in one call of `attach`.
    internal static let linkBudget = 2_000
    /// How long one turn of the main thread may go on linking and reloading before the rest
    /// waits for the next one (seconds).
    internal static let turnBudget: TimeInterval = 0.008
    /// How long a scan goes on after the window was closed, unless a test asks for less: a quarter of an hour.
    internal static let standardHiddenScanLimit: TimeInterval = 15 * 60

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// Where the trees that were read are kept.
    internal let cache: TreeCache
    /// The disks the tree can start at.
    internal let rootPopup = NSPopUpButton()
    /// The tree.
    internal let outline = TreeOutlineView()
    /// The path of the folder the cursor is on.
    internal let pathLabel = NSTextField(labelWithString: "")
    /// What was typed for the quick search.
    internal let searchField = NSTextField()
    /// The number of folders, or what is being done.
    internal let statusLabel = NSTextField(labelWithString: "")
    /// F2: reads the tree again.
    internal let rescanButton = NSButton(title: "F2 Rescan Tree", target: nil, action: nil)
    /// Shows the folder of the cursor in the source panel.
    internal let goButton = NSButton(title: "Go", target: nil, action: nil)

    /// The disks of `rootPopup`, in its order.
    internal var roots: [Place] = []
    /// The tree on screen; nil before the first load, and after it was let go.
    internal var tree: DirectoryTree?
    /// The scan that is going on.
    internal var scanner: TreeScanner?
    /// Whether the tree has hidden folders.
    internal var showHidden = false
    /// The tree on screen is all there is to know: false after an abort or for a cached partial tree.
    internal var isComplete = true
    /// The cache holds what the tree holds, so the tree may be dropped when the window closes.
    internal var treeIsInCache = false
    /// How long a scan may go on after its window was closed.
    internal let hiddenScanLimit: TimeInterval
    /// Tells the user that a quick search found nothing.
    internal let beep: @MainActor () -> Void
    /// Counts the calls of `show`, so that the answer of the disks to an older one is dropped.
    private var showCounter = 0
    /// The window is on screen (it is still `isVisible` while it closes).
    internal var isShown = false
    /// Counts the loads; see the threading note above.
    internal var generation = 0
    /// Cached trees are read and built here, and big trees freed.
    internal let reading = DispatchQueue(label: "afm.places.tree", qos: .userInitiated, attributes: .concurrent)
    /// Scans run here: a scan is a background job and gives way to everything the user does.
    internal let scanning = DispatchQueue(label: "afm.places.tree-scan", qos: .utility)
    /// Folders the user opens before the scan reached them are read here, one after the other,
    /// and each only once while it is waiting or being read.
    internal let demand = DispatchQueue(label: "afm.places.tree-demand", qos: .userInitiated)
    /// The folders waiting on `demand` or being read there.
    internal var demanded = Set<ObjectIdentifier>()
    /// The key (location and hidden folders) of the scan that runs, for its store ticket.
    internal var scanKey: String?
    /// Folders linked whose rows must be loaded again, once each, when their turn comes.
    internal var reloadQueue: [TreeNode] = []
    /// The folders in `reloadQueue`.
    internal var reloadQueued = Set<ObjectIdentifier>()
    /// Folders read and found to have no subfolders, whose disclosure triangle may still show
    /// on a row: dropped from this set when their row is next on screen after a turn.
    internal var emptied = Set<ObjectIdentifier>()
    /// Which scan of each tree stores its result last: an older one that ends late must not
    /// replace what a newer one stored.
    internal let storeTickets = StoreTickets()
    /// The number of the quick search that is going on in slices.
    internal var searchCounter = 0
    /// Scanned folders waiting to be linked, oldest first, with the load they belong to.
    internal var waiting: [(level: TreeScanner.Level, generation: Int)] = []
    /// How far the first waiting folder is linked.
    internal var waitingLinked = 0
    /// Entries of `waiting` before this one are done with; they are dropped now and then.
    internal var waitingHead = 0
    /// Whether a later turn of linking is asked for already.
    internal var isLinking = false

    /// Puts the window on screen.
    ///
    /// Tests replace it, so that no window shows in the session they run in, and look at what it
    /// was asked to show.
    internal var present: @MainActor (NSWindowController) -> Void = { $0.showWindow(nil) }

    /// The folder the cursor is on.
    internal var selectedNode: TreeNode? {
        outline.item(atRow: outline.selectedRow) as? TreeNode
    }

    /// `hiddenScanLimit`: how long a scan goes on after the window was closed
    /// (`standardHiddenScanLimit`); `beep`: the sound of a search that found nothing.
    ///
    /// Tests pass their own.
    internal init(
        kernel: Kernel,
        cache: TreeCache,
        hiddenScanLimit: TimeInterval,
        beep: @escaping @MainActor () -> Void
    ) {
        self.kernel = kernel
        self.cache = cache
        self.hiddenScanLimit = hiddenScanLimit
        self.beep = beep
        let window = TreeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Directory Tree"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 300)
        window.center()
        super.init(window: window)
        window.delegate = self
        // Esc aborts a running scan; when idle it closes the window.
        window.onEscape = { [weak self] in
            guard let self, scanner != nil, let tree else {
                return false
            }
            stopScanning(tree)
            return true
        }
        window.onRescanKey = { [weak self] in self?.rescan() }
        buildContent(in: window)
    }

    /// Not used: the window is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) { fatalError("not used") }

    /// Whether `event` is a key that reads the tree again: F2 or Ctrl+R.
    internal static func isRescanKey(_ event: NSEvent) -> Bool {
        Shortcut.f(2).matches(event) || Shortcut(.character("r"), .control).matches(event)
    }

    /// Makes the folder asked for part of the tree: the way to it is known without reading anything.
    internal static func include(_ directory: URL, in tree: DirectoryTree) {
        if let path = tree.relativePath(of: directory) {
            _ = tree.node(at: path, creating: true)
        }
    }

    // MARK: Opening

    /// Shows the tree of the volume `directory` is on, with the cursor on `directory`.
    internal func show(for directory: URL, showHidden: Bool) {
        guard let provider = try? kernel.fileSystems.provider(for: directory) else {
            return
        }
        isShown = true
        present(self)
        window?.makeFirstResponder(outline)
        searchField.stringValue = ""
        if tree == nil {
            statusLabel.stringValue = "Reading the directory tree…"
        }
        showCounter += 1
        let counter = showCounter
        let providers = kernel.fileSystems.all
        // Asking the disks which places there are can take a while: not on the main thread.
        reading.async { [weak self] in
            let providerRoot = provider.root(of: directory)
            let places = providers.flatMap { $0.places() }
            DispatchQueue.main.async { [weak self] in
                guard let self, showCounter == counter else {
                    return
                }
                finishShowing(directory, showHidden: showHidden, providerRoot: providerRoot, places: places)
            }
        }
    }

    /// The disks answered: the roots are offered, and the tree of `directory` is shown.
    private func finishShowing(_ directory: URL, showHidden: Bool, providerRoot: URL, places: [Place]) {
        // Disks of other file systems are offered too, so the tree can go anywhere a panel can.
        roots = TreeRoots.choices(
            places: places.filter { $0.url.scheme == directory.scheme }
                + places.filter { $0.url.scheme != directory.scheme },
            providerRoot: providerRoot
        )
        rootPopup.removeAllItems()
        for place in roots {
            let path = kernel.fileSystems.displayPath(place.url)
            rootPopup.menu?
                .addItem(
                    NSMenuItem(
                        title: place.name.isEmpty || place.name == path ? path : "\(place.name)  (\(path))",
                        action: nil,
                        keyEquivalent: ""
                    )
                )
        }
        let root = TreeRoots.root(for: directory, places: places, providerRoot: providerRoot)
        // The root is one of the disks offered (the first is selected otherwise).
        if let index = roots.firstIndex(where: { $0.url.isSameLocation(as: root) }) {
            rootPopup.selectItem(at: index)
        }
        if let tree, tree.rootURL.isSameLocation(as: root), self.showHidden == showHidden {
            // The same tree as last time: only the cursor moves.
            Self.include(directory, in: tree)
            outline.reloadData()
            outline.expandItem(tree.root)
            reveal(directory, in: tree)
            if scanner == nil {
                showCount()
            } else {
                statusLabel.stringValue = "Reading directories… (Esc to abort)"
            }
        } else {
            self.showHidden = showHidden
            load(root, selecting: directory, rescanning: false)
        }
    }

    /// Another disk was chosen: its tree is shown, with the cursor on its root.
    @objc
    internal func rootChosen() {
        guard roots.indices.contains(rootPopup.indexOfSelectedItem) else {
            return
        }
        searchField.stringValue = ""
        let root = roots[rootPopup.indexOfSelectedItem].url
        load(root, selecting: root, rescanning: false)
        window?.makeFirstResponder(outline)
    }

    /// F2: the tree on screen is read again; the cursor stays on its folder.
    @objc
    internal func rescan() {
        guard let tree else {
            return
        }
        load(tree.rootURL, selecting: selectedNode.map(tree.url(of:)) ?? tree.rootURL, rescanning: true)
    }

    // MARK: Result

    /// Enter or Go: the source panel shows the folder of the cursor, and the window closes.
    @objc
    internal func accept() {
        guard let tree, let node = selectedNode else {
            return
        }
        let url = tree.url(of: node)
        close()
        // While a job runs the panels stay where they are, as for every command that moves them.
        guard !kernel.jobs.isBusy else {
            kernel.commands.onRejected()
            return
        }
        kernel.panels.source.show(url)
    }

    /// Cancel: the window closes.
    @objc
    internal func cancel() {
        close()
    }

    /// The window closes: a scan goes on without it for `hiddenScanLimit` at most; the tree goes when the cache
    /// has it.
    internal func windowWillClose(_: Notification) {
        isShown = false
        showCounter += 1
        guard scanner != nil else {
            releaseTreeIfCached()
            return
        }
        // The scan goes on without the window, for a while at most.
        let current = generation
        DispatchQueue.main.asyncAfter(
            deadline: .now() + hiddenScanLimit
        ) { [weak self] in
            guard let self, generation == current, !isShown, scanner != nil, let tree else {
                return
            }
            stopScanning(tree)
            releaseTreeIfCached()
        }
    }

    /// The program quits: a scan that goes on without a window ends now.
    internal func shutDown() {
        scanner?.cancellation.cancel()
        scanner = nil
        generation += 1
        close()
    }
}
