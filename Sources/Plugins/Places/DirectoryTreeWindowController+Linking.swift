import AFMContracts
import AFMKernel
import AppKit

/// Linking what was read into the tree on screen, a bounded amount per turn, and moving the cursor.
extension DirectoryTreeWindowController {
    /// Links the waiting folders into the tree and loads their rows again, for `turnBudget`
    /// seconds at most; when more is waiting, the rest follows in a later turn, so that events
    /// and drawing come in between.
    internal func linkWaiting() {
        guard let tree else {
            (waiting, waitingHead, waitingLinked) = ([], 0, 0)
            (reloadQueue, reloadQueued) = ([], [])
            return
        }
        // Without a window the tree is only filled; the outline is loaded when the window returns.
        let visible = isShown
        let began = Date()
        func overBudget() -> Bool { Date().timeIntervalSince(began) > Self.turnBudget }
        linkLevels(into: tree, visible: visible, until: overBudget)
        if visible {
            reloadQueuedRows(tree, until: overBudget)
            statusLabel.stringValue = "Reading directories: \(Format.bytes(Int64(tree.count))) (Esc to abort)"
        }
        if waitingHead * 2 > waiting.count {
            waiting.removeFirst(waitingHead)
            waitingHead = 0
        }
        guard !waiting.isEmpty || !reloadQueue.isEmpty else {
            if visible, scanner == nil {
                showCount()
            }
            return
        }
        // One later turn at a time is asked for; a call in between links what it can itself.
        if !isLinking {
            isLinking = true
            DispatchQueue.main.async { [weak self] in
                self?.isLinking = false
                self?.linkWaiting()
            }
        }
    }

    /// Links the waiting folders of the current load into `tree` until `stop` says so; with `visible`, the
    /// folders whose rows change are queued for a reload.
    private func linkLevels(into tree: DirectoryTree, visible: Bool, until stop: () -> Bool) {
        while waitingHead < waiting.count, !stop() {
            let (level, levelGeneration) = waiting[waitingHead]
            guard levelGeneration == generation else {
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
                if visible, let node = tree.node(at: level.path) {
                    queueReload(node)
                }
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
    }

    /// A folder whose children changed has its rows loaded again, once, in a coming turn.
    private func queueReload(_ node: TreeNode) {
        guard reloadQueued.insert(ObjectIdentifier(node)).inserted else {
            return
        }
        reloadQueue.append(node)
    }

    /// Loads the rows of the queued folders again, as long as `stop` says no.
    ///
    /// Only a folder that is open has rows below it to load; one that is shut shows nothing of its
    /// children, and one that is not on screen is shown anew when its parent is opened. The cursor
    /// is put back on its folder afterwards, once, because rows may have come in above it.
    private func reloadQueuedRows(_ tree: DirectoryTree, until stop: () -> Bool) {
        guard !reloadQueue.isEmpty else {
            return
        }
        let selected = selectedNode
        var handled = 0
        while handled < reloadQueue.count, !stop() || handled == 0 {
            let node = reloadQueue[handled]
            handled += 1
            reloadQueued.remove(ObjectIdentifier(node))
            if node === tree.root || outline.isItemExpanded(node) {
                outline.reloadItem(node, reloadChildren: true)
            }
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
            if row >= 0, row != outline.selectedRow {
                outline.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
    }

    /// A folder the scan has not reached is read on its own when the user opens it.
    internal func outlineViewItemWillExpand(_ notification: Notification) {
        guard let tree, let node = notification.userInfo?["NSObject"] as? TreeNode, !node.isScanned,
            let provider = try? kernel.fileSystems.provider(for: tree.rootURL)
        else { return }
        let (current, path, url) = (generation, tree.relativePath(of: node), tree.url(of: node))
        let reader = TreeScanner(root: url, provider: provider, showHidden: showHidden)
        let id = ObjectIdentifier(node)
        guard demanded.insert(id).inserted else {
            return
        }
        // Only carried through the background thread: they are used on the main thread again.
        let shown = Handover((tree, node))
        demand.async { [weak self] in
            let names = TreeScanner.sorted(reader.subfolders(of: url)).map(\.name)
            // The nodes are made here, not on the main thread, and handed over.
            let level = Handover(TreeScanner.Level(path: path, children: names, isSorted: true))
            DispatchQueue.main.async { [weak self] in
                let (shownTree, shownNode) = shown.value
                let read = level.value
                self?.demanded.remove(id)
                // A scan that got here first has the same answer.
                guard let self, generation == current || self.tree === shownTree, !shownNode.isScanned else {
                    return
                }
                // One folder, read on its own: linked at once.
                waiting.append((read, generation))
                linkWaiting()
                if scanner == nil {
                    showCount()
                }
            }
        }
    }

    /// Opens the folders above the node of `directory` (or the nearest one the tree has) and
    /// puts the cursor on it.
    internal func reveal(_ directory: URL, in tree: DirectoryTree) {
        if let node = tree.nearestNode(to: directory) {
            reveal(node)
        }
    }

    /// Opens the folders above `node` and puts the cursor on it.
    internal func reveal(_ node: TreeNode) {
        var ancestors: [TreeNode] = []
        var current = node.parent
        while let step = current {
            (ancestors, current) = (ancestors + [step], step.parent)
        }
        for ancestor in ancestors.reversed() {
            outline.expandItem(ancestor)
        }
        // The folders above are open: the node has its row.
        outline.selectRowIndexes([outline.row(forItem: node)], byExtendingSelection: false)
        outline.scrollRowToVisible(max(outline.selectedRow, 0))
        updatePath()
    }

    /// Shows the path of the folder the cursor is on.
    internal func updatePath() {
        pathLabel.stringValue =
            tree.flatMap { tree in selectedNode.map { kernel.fileSystems.displayPath(tree.url(of: $0)) } } ?? ""
    }
}
