import AFMKernel
public import Foundation

/// The folders below one root, as far as they are known.
///
/// The tree is filled level by level while a scan runs, or all at once from the cache.
///
/// **Threading.** Not synchronized: a tree is built on one thread and may then be handed to
/// another (the window builds a cached tree in the background and shows it on the main thread).
public final class DirectoryTree {
    /// How far a quick search has come: it found a folder, found none in the whole tree, or
    /// used up its time and goes on from `node` with `remaining` folders still to look at.
    public enum SearchProgress {
        /// The folder found.
        case found(TreeNode)
        /// No folder in the whole tree fits.
        case notFound
        /// The time is up; the search goes on from `node`, with `remaining` folders still to look at.
        case pending(node: TreeNode, remaining: Int)
    }

    /// The location of the root.
    public let rootURL: URL
    /// The root's node, which has an empty name.
    public let root: TreeNode
    /// The number of folders below the root.
    public internal(set) var count = 0
    /// Changes with every change of the tree; a result found for one revision holds only for it.
    internal var revision = 0
    /// A search text that matched nothing anywhere, and the revision it was tried on.
    private var failedSearch: (text: String, revision: Int)?

    /// Every folder below the root as a relative path, parents before their children: the
    /// form the cache stores.
    public var paths: [String] {
        var list: [String] = []
        list.reserveCapacity(count)
        func walk(_ node: TreeNode, _ prefix: String) {
            for child in node.children {
                let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
                list.append(path)
                walk(child, path)
            }
        }
        walk(root, "")
        return list
    }

    /// A tree of the root alone, with nothing read yet.
    public init(rootURL: URL) {
        self.rootURL = rootURL
        root = TreeNode(name: "", parent: nil)
    }

    /// A tree from a list of folder paths relative to the root, as the cache keeps them.
    ///
    /// Every folder that comes with `complete` counts as read, except those in `unscanned` (folders
    /// the scan left out on purpose or had not reached).
    public convenience init(rootURL: URL, paths: [String], unscanned: [String] = [], complete: Bool = true) {
        self.init(rootURL: rootURL)
        for path in paths {
            _ = node(at: path, creating: true)
        }
        if complete {
            markScanned(root)
        }
        for path in unscanned {
            node(at: path)?.isScanned = false
        }
    }

    /// Whether `first` stands before `second` in a folder: the kernel's order of names, digits
    /// by their value.
    ///
    /// One comparison makes the keys of both names, which costs about a microsecond: for one pair.
    /// A list is put in order with `sorted(names:)`, which makes each name's key once.
    internal static func compare(_ first: String, _ second: String) -> Bool {
        Sorter.compare(first, second, numeric: true) == .orderedAscending
    }

    /// Names in the order of the tree.
    internal static func sorted(names: some Sequence<String>) -> [String] {
        Sorter.sorted(Array(names), numeric: true) { $0 }
    }

    /// The path of `url` relative to `root`, with `/` between the names; empty for the root itself, nil when
    /// `url` is not below it.
    public static func relativePath(of url: URL, below root: URL) -> String? {
        if url.isSameLocation(as: root) {
            return ""
        }
        guard url.isInside(root) else {
            return nil
        }
        let rootDepth = root.standardized.pathComponents.filter { $0 != "/" }.count
        return url.standardized.pathComponents.filter { $0 != "/" }.dropFirst(rootDepth).joined(separator: "/")
    }

    /// The names of a relative path, cut at the `/` byte.
    ///
    /// (Not at the character `/`: a folder whose name begins with a combining mark would make `/`
    /// and the mark one character.).
    internal static func components(of path: String) -> [String] {
        path.utf8.split(separator: 0x2F).map { name in String(Substring(name)) }
    }

    /// The nodes for the subfolders `names` of one folder, in display order and without
    /// doubles, not yet part of any tree: this is the work of `setChildren` that does not
    /// touch the tree, so a scan does it on its own thread and the tree only links the result
    /// (`attach`). `sorted` says the names come in display order already.
    public static func makeNodes(_ names: [String], sorted: Bool = false) -> [TreeNode] {
        let ordered = sorted ? names : Array(Set(names)).sorted(by: compare)
        return ordered.enumerated()
            .map { index, name in
                let node = TreeNode(name: name, parent: nil)
                node.indexInParent = index
                return node
            }
    }

    /// Marks `node` and everything below it as read.
    private func markScanned(_ node: TreeNode) {
        node.isScanned = true
        node.children.forEach(markScanned)
    }

    // MARK: Paths

    /// The path of a folder relative to the root, with `/` between the names; empty for the root.
    public func relativePath(of node: TreeNode) -> String {
        var names: [String] = []
        var current: TreeNode? = node
        while let step = current, step !== root {
            names.append(step.name)
            current = step.parent
        }
        return names.reversed().joined(separator: "/")
    }

    /// The location of the folder of `node`.
    public func url(of node: TreeNode) -> URL {
        Self.components(of: relativePath(of: node)).reduce(rootURL) { $0.appending(name: $1) }
    }

    /// The path of `url` relative to the root; nil when it is not the root or below it.
    public func relativePath(of url: URL) -> String? {
        Self.relativePath(of: url, below: rootURL)
    }

    /// The node of a relative path.
    ///
    /// With `creating`, missing folders on the way are added (in their sorted place); they do not
    /// count as read.
    public func node(at path: String, creating: Bool = false) -> TreeNode? {
        var node = root
        for name in Self.components(of: path) {
            if let child = node.child(named: name) {
                node = child
            } else if creating {
                node = insert(name, into: node)
            } else {
                return nil
            }
        }
        return node
    }

    /// The node of a location, or of its deepest known ancestor.
    public func nearestNode(to url: URL) -> TreeNode? {
        guard let path = relativePath(of: url) else {
            return nil
        }
        var node = root
        for name in Self.components(of: path) {
            guard let child = node.child(named: name) else { break }
            node = child
        }
        return node
    }

    /// Adds a folder called `name` to `parent`, in its sorted place, and returns its node.
    private func insert(_ name: String, into parent: TreeNode) -> TreeNode {
        let node = TreeNode(name: name, parent: parent)
        if let last = parent.children.last, !Self.compare(last.name, name) {
            // The children are in order: the place is found by halving, not by asking each of them.
            var (low, high) = (0, parent.children.count)
            while low < high {
                let middle = (low + high) / 2
                if Self.compare(name, parent.children[middle].name) {
                    high = middle
                } else {
                    low = middle + 1
                }
            }
            let position = low
            parent.children.insert(node, at: position)
            for index in position..<parent.children.count {
                parent.children[index].indexInParent = index
            }
        } else {
            node.indexInParent = parent.children.count
            parent.children.append(node)
        }
        // An index that was complete stays so; one that was not is still not.
        parent.childIndex[name] = node
        // A read of this folder is going on in turns: it meets the node when it gets to the name.
        parent.attaching?.known[name] = node
        count += 1
        revision += 1
        return node
    }

    // MARK: Quick search

    /// The folder after `node` in display order (as if everything were expanded), wrapping
    /// around at the end; `forward: false` gives the one before.
    public func neighbour(of node: TreeNode, forward: Bool) -> TreeNode {
        if forward {
            if let first = node.children.first {
                return first
            }
            var current = node
            while let parent = current.parent {
                if current.indexInParent + 1 < parent.children.count {
                    return parent.children[current.indexInParent + 1]
                }
                current = parent
            }
            return root
        }
        guard let parent = node.parent else {
            return deepestLast(root)
        }
        guard node.indexInParent > 0 else {
            return parent
        }
        return deepestLast(parent.children[node.indexInParent - 1])
    }

    /// The last folder of `node` in display order: its last child's last child, and so on.
    private func deepestLast(_ node: TreeNode) -> TreeNode {
        var current = node
        while let last = current.children.last {
            current = last
        }
        return current
    }

    /// The next folder whose name fits what was typed (spec 12 › Controls and keys), searching
    /// from `start` through the whole tree and around.
    ///
    /// With `includingStart`, the folder the cursor is on may be the answer (while the user is
    /// still typing).
    public func find(_ typed: String, from start: TreeNode?, forward: Bool = true, includingStart: Bool = false)
        -> TreeNode?
    {
        switch search(typed, from: start, forward: forward, includingStart: includingStart, timeBudget: nil) {
        case .found(let node):
            return node

        case .notFound, .pending:
            return nil
        }
    }

    /// The same search in slices: it looks at folders for at most `timeBudget` seconds and then
    /// says where it stopped (`pending`), so that a tree of millions of folders never holds the
    /// caller up.
    ///
    /// To go on, call again with `from` the pending node, `includingStart` true and `remaining` as
    /// given. A nil budget searches to the end.
    public func search(
        _ typed: String,
        from start: TreeNode?,
        forward: Bool = true,
        includingStart: Bool = false,
        remaining: Int? = nil,
        timeBudget: TimeInterval? = nil
    ) -> SearchProgress {
        let pattern = TreeQuickSearch(typed)
        guard !pattern.isEmpty, !root.children.isEmpty else {
            return .notFound
        }
        // A start that matched nothing anywhere is matched by no longer start either.
        if let failed = failedSearch, failed.revision == revision, !pattern.hasWildcards,
            pattern.text.hasPrefix(failed.text)
        {
            return .notFound
        }
        let origin = start ?? root
        var node = includingStart ? origin : neighbour(of: origin, forward: forward)
        var left = remaining ?? count + 1
        let began = Date()
        var sinceClock = 0
        while left > 0 {
            if node !== root, pattern.matches(folded: node.folded) {
                return .found(node)
            }
            node = neighbour(of: node, forward: forward)
            left -= 1
            sinceClock += 1
            if let timeBudget, sinceClock >= 512 {
                sinceClock = 0
                if Date().timeIntervalSince(began) > timeBudget, left > 0 {
                    return .pending(node: node, remaining: left)
                }
            }
        }
        if !pattern.hasWildcards {
            failedSearch = (pattern.text, revision)
        }
        return .notFound
    }

    deinit {
        // Nothing to release.
    }
}
