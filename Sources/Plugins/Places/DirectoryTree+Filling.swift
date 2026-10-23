/// Filling the tree: the subfolders of a folder that was read, all at once or in turns.
extension DirectoryTree {
    /// A folder has been read: `names` are all its subfolders.
    ///
    /// Known ones keep their nodes (and what is below them), new ones are added and vanished ones
    /// dropped. Returns the folder's node; nil when the folder itself is no longer in the tree.
    @discardableResult
    public func setChildren(_ names: [String], ofPath path: String, sorted: Bool = false) -> TreeNode? {
        guard let node = node(at: path) else {
            return nil
        }
        revision += 1
        if node.children.isEmpty {
            // The usual case while scanning: nothing is known yet, so nothing is compared.
            let ordered = sorted ? names : Self.sorted(names: Set(names))
            node.children = ordered.enumerated()
                .map { index, name in
                    let child = TreeNode(name: name, parent: node)
                    child.indexInParent = index
                    return child
                }
            count += ordered.count
        } else {
            let known = Dictionary(node.children.map { ($0.name, $0) }) { first, _ in first }
            let wanted = Set(names)
            for child in node.children where !wanted.contains(child.name) {
                count -= 1 + folderCount(below: child)
            }
            node.children = (sorted ? names : Self.sorted(names: wanted)).enumerated()
                .map { index, name in
                    let child =
                        known[name]
                        ?? {
                            count += 1
                            return TreeNode(name: name, parent: node)
                        }()
                    child.indexInParent = index
                    return child
                }
        }
        node.childIndex = [:]
        node.attaching = nil
        node.isScanned = true
        return node
    }

    /// What `setChildren` does for a folder, with the nodes made beforehand by `makeNodes`.
    ///
    /// A folder with nothing known gets them linked in; one with known subfolders keeps those (and
    /// what is below them) and takes the new nodes for the new names.
    ///
    /// Linking is bounded by `limit`: at most that many nodes from `start` on, so that a
    /// folder of a million subfolders can be taken over in several turns. The result is the
    /// index to go on from (`nodes.count` when the folder is done, which marks it as read).
    /// A folder that was read by someone else in between is left as it is.
    @discardableResult
    public func attach(_ nodes: [TreeNode], ofPath path: String, from start: Int = 0, limit: Int = .max) -> Int {
        guard let node = node(at: path), start == 0 || !node.isScanned else {
            return nodes.count
        }
        revision += 1
        if start == 0 {
            // A folder that has children (the folders on the way to the one the window opened
            // are made beforehand) is rebuilt: known ones keep their nodes, and what is below them.
            let old = node.children
            node.attaching = TreeNode.Attach(
                known: Dictionary(old.map { ($0.name, $0) }) { first, _ in first },
                isMerge: !old.isEmpty
            )
        }
        let attach = node.attaching ?? TreeNode.Attach(known: [:], isMerge: false)
        node.attaching = attach
        let end = limit >= nodes.count - start ? nodes.count : start + limit
        if attach.isMerge {
            attach.built.reserveCapacity(nodes.count)
            for fresh in nodes[start..<end] {
                let child: TreeNode
                if let known = attach.known[fresh.name] {
                    child = known
                    attach.seen.insert(known.name)
                    attach.places.append((known, attach.built.count))
                } else {
                    count += 1
                    fresh.parent = node
                    fresh.indexInParent = attach.built.count
                    child = fresh
                }
                attach.built.append(child)
            }
        } else {
            if start == 0 {
                node.children.reserveCapacity(nodes.count)
            }
            for fresh in nodes[start..<end] where attach.known[fresh.name] == nil {
                fresh.parent = node
                fresh.indexInParent = node.children.count
                node.children.append(fresh)
                count += 1
            }
        }
        node.childIndex = [:]
        guard end == nodes.count else {
            return end
        }
        finish(attach, of: node, with: nodes)
        return end
    }

    /// The last turn of `attach`: the new list takes the place of the old one.
    private func finish(_ attach: TreeNode.Attach, of node: TreeNode, with nodes: [TreeNode]) {
        defer {
            node.attaching = nil
            node.childIndex = [:]
            node.isScanned = true
        }
        if attach.isMerge {
            // What was there and is not in the new list has vanished.
            for (name, child) in attach.known where !attach.seen.contains(name) {
                count -= 1 + folderCount(below: child)
            }
            for (known, index) in attach.places {
                known.indexInParent = index
            }
            node.children = attach.built
            return
        }
        guard !attach.known.isEmpty else {
            return
        }
        // Folders were made while the nodes were being linked: the list is the new nodes' order, with those nodes.
        var kept: [TreeNode] = []
        kept.reserveCapacity(nodes.count)
        var used = Set<String>()
        for fresh in nodes {
            let child = attach.known[fresh.name] ?? fresh
            if attach.known[fresh.name] != nil {
                used.insert(fresh.name)
            }
            child.indexInParent = kept.count
            kept.append(child)
        }
        for (name, child) in attach.known where !used.contains(name) {
            count -= 1 + folderCount(below: child)
        }
        node.children = kept
    }

    /// How many folders are below `node`, at any depth.
    private func folderCount(below node: TreeNode) -> Int {
        node.children.reduce(0) { $0 + 1 + folderCount(below: $1) }
    }
}
