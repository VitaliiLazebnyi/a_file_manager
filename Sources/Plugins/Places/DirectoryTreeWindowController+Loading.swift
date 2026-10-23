import AFMContracts
import AFMKernel
import AppKit

/// Loading a tree: from the cache, or by a scan of the disk, and letting it go again.
extension DirectoryTreeWindowController {
    /// Numbers the scans of each tree (by location key) and lets only the latest store its result.
    ///
    /// All state is guarded by `lock`.
    internal final class StoreTickets: @unchecked Sendable {
        /// Guards everything below.
        private let lock = NSLock()
        /// The latest ticket of each tree.
        private var latest: [String: Int] = [:]
        /// The last ticket handed out.
        private var counter = 0

        /// A new ticket for the tree under `key`, which makes every earlier one of it stale.
        internal func next(for key: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            counter += 1
            latest[key] = counter
            return counter
        }

        /// Runs `store` when `ticket` is still the latest of its tree.
        internal func storeIfLatest(_ ticket: Int, for key: String, _ store: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            if latest[key] == ticket {
                store()
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Shows the tree of `root` with the cursor on `directory`: from the cache, else by a scan; a rescan always
    /// scans.
    internal func load(_ root: URL, selecting directory: URL, rescanning: Bool) {
        scanner?.cancellation.cancel()
        // The scan that is replaced does not store what it read until now: the cache, or the
        // scan that comes next, has the better tree.
        if scanner != nil, let scanKey {
            _ = storeTickets.next(for: scanKey)
        }
        scanner = nil
        generation += 1
        let current = generation
        guard !rescanning else {
            scan(root, selecting: directory, generation: current, rescanning: true)
            return
        }
        statusLabel.stringValue = "Reading the directory tree…"
        let hidden = showHidden
        reading.async { [weak self, cache] in
            // Reading the cache file and building the tree both take a while for a large disk.
            let entry = cache.entry(for: root, showHidden: hidden)
            // The tree is built here and let go of: from now on it belongs to the main thread.
            let built = Handover(entry.map { DirectoryTree(rootURL: root, paths: $0.paths, unscanned: $0.unscanned) })
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == current else {
                    return
                }
                guard let cached = built.value, let entry else {
                    return scan(root, selecting: directory, generation: current, rescanning: false)
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

    /// Lets go of the tree on screen; a large tree is freed on a background thread.
    internal func releaseTree() {
        let old = tree
        let (unlinked, unreloaded) = (waiting, reloadQueue)
        tree = nil
        (reloadQueue, reloadQueued, emptied, waiting, waitingHead, waitingLinked) = ([], [], [], [], 0, 0)
        // The nodes of a tree of millions of folders are freed away from the main thread, also
        // those that were made and not linked yet. The main thread has let go of them; they are
        // only freed there.
        let released = Handover((old, unlinked, unreloaded))
        reading.async {
            withExtendedLifetime(released) {
                // Nothing to do: the nodes go when this block ends.
            }
        }
    }

    /// Shows `tree` instead of the one on screen, with the cursor on `directory`.
    internal func adopt(_ tree: DirectoryTree, selecting directory: URL) {
        if self.tree != nil {
            releaseTree()
        }
        self.tree = tree
        outline.reloadData()
        outline.expandItem(tree.root)
        reveal(directory, in: tree)
    }

    /// The number of folders, and whether there are more to read, in the status line.
    internal func showCount() {
        guard let tree else {
            statusLabel.stringValue = ""
            return
        }
        statusLabel.stringValue =
            "\(Format.bytes(Int64(tree.count))) directories"
            + (isComplete ? "" : ", incomplete: folders are read when opened, F2 reads the rest")
    }

    /// Reads the tree from its file system.
    ///
    /// A rescan fills the tree on screen, so the outline stays as it is while folders come and go.
    private func scan(_ root: URL, selecting directory: URL, generation current: Int, rescanning: Bool) {
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
        let hidden = showHidden
        let reader = TreeScanner(root: root, provider: provider, showHidden: hidden, isExcluded: exclusions(for: root))
        scanner = reader
        statusLabel.stringValue = "Reading directories… (Esc to abort)"
        let (tickets, key) = (storeTickets, root.locationKey + (hidden ? "\u{0}hidden" : ""))
        let ticket = tickets.next(for: key)
        scanKey = key
        scanning.async { [weak self, cache] in
            let completed = reader.run { levels in
                // The scan made the levels and their nodes for the main thread and lets go of them.
                let handed = Handover(levels)
                DispatchQueue.main.async { [weak self] in
                    self?.receive(handed.value, generation: current)
                }
            }
            // The scanner has collected the paths itself: nothing is built from the tree on the
            // main thread. What was read is kept, also when the scan was stopped; a rescan that
            // is stopped leaves the earlier cache alone.
            let stored = completed || !rescanning
            if stored {
                tickets.storeIfLatest(ticket, for: key) {
                    cache.store(
                        reader.paths,
                        for: root,
                        unscanned: reader.unscanned,
                        isComplete: completed,
                        showHidden: hidden
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.scanEnded(generation: current, completed: completed, stored: stored)
            }
        }
    }

    /// Folders the scan of load `current` read: they are linked into the tree, unless the load was replaced.
    private func receive(_ levels: [TreeScanner.Level], generation current: Int) {
        guard generation == current else {
            return
        }
        waiting += levels.map { ($0, current) }
        linkWaiting()
    }

    /// The scan of load `current` is over; `stored` says whether the cache has its tree now.
    private func scanEnded(generation current: Int, completed: Bool, stored: Bool) {
        guard generation == current else {
            return
        }
        scanner = nil
        isComplete = completed
        treeIsInCache = stored
        if isShown {
            showCount()
        } else {
            releaseTreeIfCached()
        }
    }

    /// The cache has what the tree has: the tree goes while no window shows it.
    internal func releaseTreeIfCached() {
        guard scanner == nil, treeIsInCache, !isShown else {
            return
        }
        releaseTree()
        outline.reloadData()
    }

    /// Esc: the scan of `tree` is aborted; what it has read stays in the cache, marked as incomplete.
    internal func stopScanning(_ tree: DirectoryTree) {
        scanner?.cancellation.cancel()
        scanner = nil
        isComplete = false
        // A late result of the scan must not reach the tree; the scan stores its own paths.
        generation += 1
        statusLabel.stringValue = "\(Format.bytes(Int64(tree.count))) directories, reading aborted"
    }

    /// Folders that are shown but not read with the rest: other disks mounted inside this one.
    ///
    /// On the start-up disk these are `/Volumes` and the system's own mount points, which show the
    /// same files a second time. The answer is a fixed set, so any thread may ask.
    private func exclusions(for root: URL) -> @Sendable (URL) -> Bool {
        var excluded = Set(roots.filter { $0.kind != .home && $0.url.isInside(root) }.map(\.url.locationKey))
        if root.isFileURL, root.path == "/" {
            excluded.formUnion(
                ["/Volumes", "/System/Volumes", "/dev"].map { URL(fileURLWithPath: $0, isDirectory: true).locationKey }
            )
        }
        return { [excluded] in excluded.contains($0.locationKey) }
    }
}
