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
final class DirectoryTreeWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource,
    NSOutlineViewDelegate,
    NSTextFieldDelegate
{
    private final class TreeOutlineView: NSOutlineView {
        var onKey: ((NSEvent) -> Bool)?

        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }

        /// Option-click on a disclosure triangle (and Option-Right) open a folder and everything
        /// below it: on a disk that is every row at once and a reader for each folder that has
        /// not been read. A folder opens one level.
        override func expandItem(_ item: Any?, expandChildren _: Bool) {
            super.expandItem(item, expandChildren: false)
        }
    }

    /// Rescan keys work wherever the focus is (spec 12 › Controls and keys).
    private final class TreeWindow: ToolWindow {
        var onRescanKey: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if DirectoryTreeWindowController.isRescanKey(event) { onRescanKey?() } else { super.keyDown(with: event) }
        }
    }

    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    private let cache: TreeCache
    private let rootPopup = NSPopUpButton()
    private let outline = TreeOutlineView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let searchField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let rescanButton = NSButton(title: "F2 Rescan Tree", target: nil, action: nil)
    private let goButton = NSButton(title: "Go", target: nil, action: nil)

    private var roots: [Place] = []
    private var tree: DirectoryTree?
    private var scanner: TreeScanner?
    private var showHidden = false
    /// The tree on screen is all there is to know: false after an abort or for a cached partial tree.
    private var isComplete = true
    /// The cache holds what the tree holds, so the tree may be dropped when the window closes.
    private var treeIsInCache = false
    /// How long a scan may go on after its window was closed.
    private let hiddenScanLimit: TimeInterval
    /// Tells the user that a quick search found nothing.
    private let beep: @MainActor () -> Void
    private var showCounter = 0
    /// The window is on screen (it is still `isVisible` while it closes).
    private var isShown = false
    /// Counts the loads; see the threading note above.
    private var generation = 0
    private let reading = DispatchQueue(label: "afm.places.tree", qos: .userInitiated, attributes: .concurrent)
    /// Scans run here: a scan is a background job and gives way to everything the user does.
    private let scanning = DispatchQueue(label: "afm.places.tree-scan", qos: .utility)
    /// Folders the user opens before the scan reached them are read here, one after the other,
    /// and each only once while it is waiting or being read.
    private let demand = DispatchQueue(label: "afm.places.tree-demand", qos: .userInitiated)
    private var demanded = Set<ObjectIdentifier>()
    /// The key (location and hidden folders) of the scan that runs, for its store ticket.
    private var scanKey: String?
    /// How many nodes are linked into the tree in one call of `attach`.
    static let linkBudget = 2_000
    /// How long one turn of the main thread may go on linking and reloading before the rest
    /// waits for the next one (seconds).
    static let turnBudget: TimeInterval = 0.008
    /// Folders linked whose rows must be loaded again, once each, when their turn comes.
    private var reloadQueue: [TreeNode] = []
    private var reloadQueued = Set<ObjectIdentifier>()
    /// Folders read and found to have no subfolders, whose disclosure triangle may still show
    /// on a row: dropped from this set when their row is next on screen after a turn.
    private var emptied = Set<ObjectIdentifier>()
    /// Which scan of each tree stores its result last: an older one that ends late must not
    /// replace what a newer one stored.
    private let storeTickets = StoreTickets()
    /// The quick search that is going on in slices, and the number of the search it belongs to.
    private var searchCounter = 0
    /// Scanned folders waiting to be linked, oldest first, and how far the first one is linked.
    private var waiting: [(level: TreeScanner.Level, generation: Int)] = []
    private var waitingLinked = 0
    /// Entries of `waiting` before this one are done with; they are dropped now and then.
    private var waitingHead = 0
    private var isLinking = false

    /// Numbers the scans of each tree (by location key) and lets only the latest store its result.
    /// All state is guarded by `lock`.
    private final class StoreTickets: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: [String: Int] = [:]
        private var counter = 0

        func next(for key: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            counter += 1
            latest[key] = counter
            return counter
        }

        /// Runs `store` when `ticket` is still the latest of its tree.
        func storeIfLatest(_ ticket: Int, for key: String, _ store: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            if latest[key] == ticket { store() }
        }
    }

    /// `hiddenScanLimit`: how long a scan goes on after the window was closed (a quarter of an
    /// hour); `beep`: the sound of a search that found nothing. Tests replace both.
    init(
        kernel: Kernel,
        cache: TreeCache,
        hiddenScanLimit: TimeInterval = 15 * 60,
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
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
            guard let self, scanner != nil, let tree else { return false }
            stopScanning(tree)
            return true
        }
        window.onRescanKey = { [weak self] in self?.rescan() }
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    static func isRescanKey(_ event: NSEvent) -> Bool {
        Shortcut.f(2).matches(event) || Shortcut(.character("r"), .control).matches(event)
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        rootPopup.target = self
        rootPopup.action = #selector(rootChosen)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 18
        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(accept)
        outline.onKey = { [weak self] event in self?.handleKey(event) == true }
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.placeholderString = "type to find a folder (* and ? allowed)"
        searchField.delegate = self
        rescanButton.target = self
        rescanButton.action = #selector(rescan)
        goButton.target = self
        goButton.action = #selector(accept)
        goButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))

        let searchRow = NSStackView(views: [NSTextField(labelWithString: "Quick search:"), searchField, rescanButton])
        let footer = NSStackView(views: [statusLabel, NSView(), cancelButton, goButton])
        let stack = NSStackView(views: [rootPopup, scroll, pathLabel, searchRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for part in [scroll, pathLabel, searchRow, footer] as [NSView] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
    }

    // MARK: Opening

    /// Shows the tree of the volume `directory` is on, with the cursor on `directory`.
    func show(for directory: URL, showHidden: Bool) {
        guard let provider = try? kernel.fileSystems.provider(for: directory) else { return }
        isShown = true
        showWindow(nil)
        window?.makeFirstResponder(outline)
        searchField.stringValue = ""
        if tree == nil { statusLabel.stringValue = "Reading the directory tree…" }
        showCounter += 1
        let counter = showCounter
        let providers = kernel.fileSystems.all
        // Asking the disks which places there are can take a while: not on the main thread.
        reading.async { [weak self] in
            let providerRoot = provider.root(of: directory)
            let places = providers.flatMap { $0.places() }
            DispatchQueue.main.async { [weak self] in
                guard let self, showCounter == counter else { return }
                finishShowing(directory, showHidden: showHidden, providerRoot: providerRoot, places: places)
            }
        }
    }

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
        if let index = roots.firstIndex(where: { $0.url.isSameLocation(as: root) }) { rootPopup.selectItem(at: index) }
        if let tree, tree.rootURL.isSameLocation(as: root), self.showHidden == showHidden {
            // The same tree as last time: only the cursor moves.
            Self.include(directory, in: tree)
            outline.reloadData()
            outline.expandItem(tree.root)
            reveal(directory, in: tree)
            if scanner == nil { showCount() } else { statusLabel.stringValue = "Reading directories… (Esc to abort)" }
        } else {
            self.showHidden = showHidden
            load(root, selecting: directory, rescanning: false)
        }
    }

    @objc private func rootChosen() {
        guard roots.indices.contains(rootPopup.indexOfSelectedItem) else { return }
        searchField.stringValue = ""
        let root = roots[rootPopup.indexOfSelectedItem].url
        load(root, selecting: root, rescanning: false)
        window?.makeFirstResponder(outline)
    }

    @objc private func rescan() {
        guard let tree else { return }
        load(tree.rootURL, selecting: selectedNode.map(tree.url(of:)) ?? tree.rootURL, rescanning: true)
    }

    // MARK: Loading

    private func load(_ root: URL, selecting directory: URL, rescanning: Bool) {
        scanner?.cancellation.cancel()
        // The scan that is replaced does not store what it read until now: the cache, or the
        // scan that comes next, has the better tree.
        if scanner != nil, let scanKey { _ = storeTickets.next(for: scanKey) }
        scanner = nil
        generation += 1
        let generation = generation
        guard !rescanning else {
            scan(root, selecting: directory, generation: generation, rescanning: true)
            return
        }
        statusLabel.stringValue = "Reading the directory tree…"
        let showHidden = showHidden
        reading.async { [weak self, cache] in
            // Reading the cache file and building the tree both take a while for a large disk.
            let entry = cache.entry(for: root, showHidden: showHidden)
            // The tree is built here and let go of: from now on it belongs to the main thread.
            let built = Handover(entry.map { DirectoryTree(rootURL: root, paths: $0.paths, unscanned: $0.unscanned) })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                guard let cached = built.value, let entry else {
                    return scan(root, selecting: directory, generation: generation, rescanning: false)
                }
                // The folder the panel shows is in the tree even if the cache is older than it.
                Self.include(directory, in: cached)
                adopt(cached, selecting: directory)
                isComplete = entry.isComplete
                treeIsInCache = true
                showCount()
            }
        }
    }

    /// Makes the folder asked for part of the tree: the way to it is known without reading anything.
    private static func include(_ directory: URL, in tree: DirectoryTree) {
        if let path = tree.relativePath(of: directory) { _ = tree.node(at: path, creating: true) }
    }

    /// Lets go of the tree on screen; a large tree is freed on a background thread.
    private func releaseTree() {
        let old = tree
        let (unlinked, unreloaded) = (waiting, reloadQueue)
        tree = nil
        (reloadQueue, reloadQueued, emptied, waiting, waitingHead, waitingLinked) = ([], [], [], [], 0, 0)
        // The nodes of a tree of millions of folders are freed away from the main thread, also
        // those that were made and not linked yet.
        if old != nil || !unlinked.isEmpty || !unreloaded.isEmpty {
            // The main thread has let go of them; they are only freed there.
            let released = Handover((old, unlinked, unreloaded))
            reading.async { withExtendedLifetime(released) {} }
        }
    }

    private func adopt(_ tree: DirectoryTree, selecting directory: URL) {
        if self.tree != nil { releaseTree() }
        self.tree = tree
        outline.reloadData()
        outline.expandItem(tree.root)
        reveal(directory, in: tree)
    }

    private func showCount() {
        guard let tree else {
            statusLabel.stringValue = ""
            return
        }
        statusLabel.stringValue =
            "\(Format.bytes(Int64(tree.count))) directories"
            + (isComplete ? "" : ", incomplete: folders are read when opened, F2 reads the rest")
    }

    /// Reads the tree from its file system. A rescan fills the tree on screen, so the outline
    /// stays as it is while folders come and go.
    private func scan(_ root: URL, selecting directory: URL, generation: Int, rescanning: Bool) {
        // A disk of a file system that is not there (a place another one offered).
        guard let provider = try? kernel.fileSystems.provider(for: root) else {
            statusLabel.stringValue = "This disk cannot be read."
            return
        }
        if tree?.rootURL.isSameLocation(as: root) != true {
            let fresh = DirectoryTree(rootURL: root)
            Self.include(directory, in: fresh)
            adopt(fresh, selecting: directory)
        }
        isComplete = false
        treeIsInCache = false
        let showHidden = showHidden
        let scanner = TreeScanner(
            root: root,
            provider: provider,
            showHidden: showHidden,
            isExcluded: exclusions(for: root)
        )
        self.scanner = scanner
        statusLabel.stringValue = "Reading directories… (Esc to abort)"
        let (tickets, key) = (storeTickets, root.locationKey + (showHidden ? "\u{0}hidden" : ""))
        let ticket = tickets.next(for: key)
        scanKey = key
        scanning.async { [weak self, cache] in
            let completed = scanner.run { levels in
                // The scan made the levels and their nodes for the main thread and lets go of them.
                let levels = Handover(levels)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    waiting += levels.value.map { ($0, generation) }
                    linkWaiting()
                }
            }
            // The scanner has collected the paths itself: nothing is built from the tree on the
            // main thread. What was read is kept, also when the scan was stopped; a rescan that
            // is stopped leaves the earlier cache alone.
            let stored = completed || !rescanning
            if stored {
                tickets.storeIfLatest(ticket, for: key) {
                    cache.store(
                        scanner.paths,
                        unscanned: scanner.unscanned,
                        isComplete: completed,
                        for: root,
                        showHidden: showHidden
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.scanner = nil
                isComplete = completed
                treeIsInCache = stored
                if isShown { showCount() } else { releaseTreeIfCached() }
            }
        }
    }

    /// The cache has what the tree has: the tree goes while no window shows it.
    private func releaseTreeIfCached() {
        guard scanner == nil, treeIsInCache, !isShown else { return }
        releaseTree()
        outline.reloadData()
    }

    /// Esc: the scan of `tree` is aborted; what it has read stays in the cache, marked as incomplete.
    private func stopScanning(_ tree: DirectoryTree) {
        scanner?.cancellation.cancel()
        scanner = nil
        isComplete = false
        // A late result of the scan must not reach the tree; the scan stores its own paths.
        generation += 1
        statusLabel.stringValue = "\(Format.bytes(Int64(tree.count))) directories, reading aborted"
    }

    /// The program quits: a scan that goes on without a window ends now.
    func shutDown() {
        scanner?.cancellation.cancel()
        scanner = nil
        generation += 1
        close()
    }

    /// Folders that are shown but not read with the rest: other disks mounted inside this one.
    /// On the start-up disk these are `/Volumes` and the system's own mount points, which show
    /// the same files a second time. The answer is a fixed set, so any thread may ask.
    private func exclusions(for root: URL) -> @Sendable (URL) -> Bool {
        var excluded = Set(roots.filter { $0.kind != .home && $0.url.isInside(root) }.map(\.url.locationKey))
        if root.isFileURL, root.path == "/" {
            excluded.formUnion(
                ["/Volumes", "/System/Volumes", "/dev"].map { URL(fileURLWithPath: $0, isDirectory: true).locationKey }
            )
        }
        return { [excluded] in excluded.contains($0.locationKey) }
    }

    /// Links the waiting folders into the tree and loads their rows again, for `turnBudget`
    /// seconds at most; when more is waiting, the rest follows in a later turn, so that events
    /// and drawing come in between.
    private func linkWaiting() {
        guard !isLinking else { return }
        guard let tree else {
            (waiting, waitingHead, waitingLinked) = ([], 0, 0)
            (reloadQueue, reloadQueued) = ([], [])
            return
        }
        // Without a window the tree is only filled; the outline is loaded when the window returns.
        let visible = isShown
        let began = Date()
        func overBudget() -> Bool { Date().timeIntervalSince(began) > Self.turnBudget }
        while waitingHead < waiting.count, !overBudget() {
            let (level, generation) = waiting[waitingHead]
            guard generation == self.generation else {
                (waitingHead, waitingLinked) = (waitingHead + 1, 0)
                continue
            }
            let done = tree.attach(
                level.nodes,
                ofPath: level.path,
                from: waitingLinked,
                limit: Self.linkBudget
            )
            guard done == level.nodes.count else {
                waitingLinked = done
                // The rows of a folder that is still being filled are loaded when it is done.
                if visible, let node = tree.node(at: level.path) { queueReload(node) }
                continue
            }
            (waitingHead, waitingLinked) = (waitingHead + 1, 0)
            if visible, let node = tree.node(at: level.path) {
                queueReload(node)
                for child in node.children where child.isScanned && child.children.isEmpty {
                    emptied.insert(ObjectIdentifier(child))
                }
            }
        }
        if visible { reloadQueuedRows(tree, until: overBudget) }
        if visible {
            statusLabel.stringValue = "Reading directories: \(Format.bytes(Int64(tree.count))) (Esc to abort)"
        }
        if waitingHead * 2 > waiting.count {
            waiting.removeFirst(waitingHead)
            waitingHead = 0
        }
        guard !waiting.isEmpty || !reloadQueue.isEmpty else {
            if visible, scanner == nil { showCount() }
            return
        }
        isLinking = true
        DispatchQueue.main.async { [weak self] in
            self?.isLinking = false
            self?.linkWaiting()
        }
    }

    /// A folder whose children changed has its rows loaded again, once, in a coming turn.
    private func queueReload(_ node: TreeNode) {
        guard reloadQueued.insert(ObjectIdentifier(node)).inserted else { return }
        reloadQueue.append(node)
    }

    /// Loads the rows of the queued folders again, as long as `stop` says no. Only a folder
    /// that is open has rows below it to load; one that is shut shows nothing of its children,
    /// and one that is not on screen is shown anew when its parent is opened. The cursor is
    /// put back on its folder afterwards, once, because rows may have come in above it.
    private func reloadQueuedRows(_ tree: DirectoryTree, until stop: () -> Bool) {
        guard !reloadQueue.isEmpty else { return }
        let selected = selectedNode
        var handled = 0
        while handled < reloadQueue.count, !stop() || handled == 0 {
            let node = reloadQueue[handled]
            handled += 1
            reloadQueued.remove(ObjectIdentifier(node))
            if node === tree.root || outline.isItemExpanded(node) { outline.reloadItem(node, reloadChildren: true) }
        }
        reloadQueue.removeFirst(handled)
        // A folder that turned out to have no subfolders loses its disclosure triangle; only
        // the rows on screen are looked at, which is all that takes no time on a huge tree.
        if !emptied.isEmpty {
            let rows = outline.rows(in: outline.visibleRect)
            for row in rows.location..<(rows.location + rows.length) {
                guard let node = outline.item(atRow: row) as? TreeNode, emptied.remove(ObjectIdentifier(node)) != nil
                else { continue }
                outline.reloadItem(node, reloadChildren: false)
            }
        }
        // A folder that is gone (read again without it) leaves the cursor where it is.
        if let selected {
            let row = outline.row(forItem: selected)
            if row >= 0, row != outline.selectedRow { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    /// One folder, read on its own: linked at once.
    private func apply(_ level: TreeScanner.Level) {
        waiting.append((level, generation))
        linkWaiting()
    }

    /// A folder the scan has not reached is read on its own when the user opens it.
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let tree, let node = notification.userInfo?["NSObject"] as? TreeNode, !node.isScanned,
            let provider = try? kernel.fileSystems.provider(for: tree.rootURL)
        else { return }
        let (generation, path, url) = (generation, tree.relativePath(of: node), tree.url(of: node))
        let reader = TreeScanner(root: url, provider: provider, showHidden: showHidden)
        let id = ObjectIdentifier(node)
        guard demanded.insert(id).inserted else { return }
        // Only carried through the background thread: they are used on the main thread again.
        let shown = Handover((tree, node))
        demand.async { [weak self] in
            let names = TreeScanner.sorted(reader.subfolders(of: url)).map(\.name)
            // The nodes are made here, not on the main thread, and handed over.
            let level = Handover(TreeScanner.Level(path: path, children: names, isSorted: true))
            DispatchQueue.main.async { [weak self] in
                let (tree, node) = shown.value
                let level = level.value
                self?.demanded.remove(id)
                // A scan that got here first has the same answer.
                guard let self, self.generation == generation || self.tree === tree, !node.isScanned else { return }
                apply(level)
                if scanner == nil { showCount() }
            }
        }
    }

    // MARK: Cursor and quick search

    private var selectedNode: TreeNode? {
        outline.item(atRow: outline.selectedRow) as? TreeNode
    }

    /// Opens the folders above the node of `directory` (or the nearest one the tree has) and
    /// puts the cursor on it.
    private func reveal(_ directory: URL, in tree: DirectoryTree) {
        if let node = tree.nearestNode(to: directory) { reveal(node) }
    }

    /// Opens the folders above `node` and puts the cursor on it.
    private func reveal(_ node: TreeNode) {
        var ancestors: [TreeNode] = []
        var current = node.parent
        while let step = current { (ancestors, current) = (ancestors + [step], step.parent) }
        ancestors.reversed().forEach { outline.expandItem($0) }
        // The folders above are open: the node has its row.
        outline.selectRowIndexes([outline.row(forItem: node)], byExtendingSelection: false)
        outline.scrollRowToVisible(max(outline.selectedRow, 0))
        updatePath()
    }

    private func updatePath() {
        pathLabel.stringValue =
            tree.flatMap { tree in selectedNode.map { kernel.fileSystems.displayPath(tree.url(of: $0)) } } ?? ""
    }

    /// Quick search, in slices of `turnBudget`: in a tree of millions of folders the search
    /// goes on in later turns, and a new key press or a new tree ends the one that is going on.
    private func search(forward: Bool = true, includingStart: Bool = false) {
        searchCounter += 1
        guard let tree, !searchField.stringValue.isEmpty else { return }
        continueSearch(
            in: tree,
            text: searchField.stringValue,
            from: selectedNode,
            forward: forward,
            includingStart: includingStart,
            remaining: nil,
            number: searchCounter
        )
    }

    private func continueSearch(
        in tree: DirectoryTree,
        text: String,
        from start: TreeNode?,
        forward: Bool,
        includingStart: Bool,
        remaining: Int?,
        number: Int
    ) {
        guard number == searchCounter, tree === self.tree else { return }
        switch tree.search(
            text,
            from: start,
            forward: forward,
            includingStart: includingStart,
            remaining: remaining,
            timeBudget: Self.turnBudget
        )
        {
        case .found(let match): reveal(match)
        case .none: beep()

        case .pending(let node, let left):
            DispatchQueue.main.async { [weak self] in
                self?
                    .continueSearch(
                        in: tree,
                        text: text,
                        from: node,
                        forward: forward,
                        includingStart: true,
                        remaining: left,
                        number: number
                    )
            }
        }
    }

    func controlTextDidChange(_: Notification) {
        search(includingStart: true)
    }

    /// Keys in the quick-search field: Ctrl+Enter and Ctrl+arrows step through the matches, and
    /// plain arrows move the cursor in the tree.
    func control(_: NSControl, textView _: NSTextView, doCommandBy _: Selector) -> Bool {
        handleFieldKey(NSApp.currentEvent)
    }

    /// The key press behind a command of the quick-search field, if it was one.
    func handleFieldKey(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if Shortcut(.returnKey).matches(event) || Shortcut(.enter).matches(event) {
            accept()
            return true
        }
        if handleStepKey(event) { return true }
        if Shortcut(.upArrow).matches(event) || Shortcut(.downArrow).matches(event) {
            outline.keyDown(with: event)
            return true
        }
        return false
    }

    private func handleStepKey(_ event: NSEvent) -> Bool {
        if Shortcut(.returnKey, .control).matches(event) || Shortcut(.downArrow, .control).matches(event) {
            search(forward: true)
        } else if Shortcut(.upArrow, .control).matches(event) {
            search(forward: false)
        } else {
            return false
        }
        return true
    }

    /// Keys in the tree: Enter goes there, F2 rescans, and typing fills the quick search.
    private func handleKey(_ event: NSEvent) -> Bool {
        if handleStepKey(event) { return true }
        if Self.isRescanKey(event) {
            rescan()
        } else if Shortcut(.returnKey).matches(event) || Shortcut(.enter).matches(event) {
            accept()
        } else if Shortcut(.backspace).matches(event) {
            searchField.stringValue = String(searchField.stringValue.dropLast())
            search(includingStart: true)
        } else if let typed = Self.typedText(event) {
            searchField.stringValue += typed
            search(includingStart: true)
        } else {
            return false
        }
        return true
    }

    /// What a key press types, when it types something: no control or command key, and not one
    /// of the keys that only have a code (arrows, function keys).
    private static func typedText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]), let text = event.characters, !text.isEmpty,
            text.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
            })
        else { return nil }
        return text
    }

    // MARK: Result

    @objc private func accept() {
        guard let tree, let node = selectedNode else { return }
        let url = tree.url(of: node)
        close()
        // While a job runs the panels stay where they are, as for every command that moves them.
        guard !kernel.jobs.isBusy else {
            kernel.commands.onRejected()
            return
        }
        kernel.panels.source.show(url)
    }

    @objc private func cancel() {
        close()
    }

    func windowWillClose(_: Notification) {
        isShown = false
        showCounter += 1
        if scanner != nil {
            // The scan goes on without the window, for a while at most.
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + hiddenScanLimit) {
                [weak self] in
                guard let self, generation == current, !isShown, scanner != nil, let tree else { return }
                stopScanning(tree)
                releaseTreeIfCached()
            }
        } else {
            releaseTreeIfCached()
        }
    }

    // MARK: Outline

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return tree == nil ? 0 : 1 }
        return node.children.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return tree?.root as Any }
        return node.children[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode).map { !$0.children.isEmpty || !$0.isScanned } == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("folder")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingMiddle
                return label
            }()
        if let node = item as? TreeNode, let tree {
            cell.stringValue = node === tree.root ? kernel.fileSystems.displayPath(tree.rootURL) : node.name
        }
        return cell
    }

    func outlineViewSelectionDidChange(_: Notification) {
        updatePath()
    }
}
