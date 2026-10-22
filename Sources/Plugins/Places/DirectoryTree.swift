public import AFMKernel
public import Foundation

/// One folder of a directory tree (spec 12 › Directory Tree dialog).
///
/// Nodes belong to whoever owns their `DirectoryTree`.
public final class TreeNode {
    public let name: String
    public fileprivate(set) weak var parent: TreeNode?
    /// The subfolders that are known, in display order.
    public fileprivate(set) var children: [TreeNode] = []
    /// True once the folder has been read: its children are then all there are.
    public fileprivate(set) var isScanned = false
    /// The node's place in `parent.children`, kept up to date wherever the children change, so
    /// that stepping from one folder to the next costs nothing.
    internal fileprivate(set) var indexInParent = 0
    /// The name in lower case, made when a quick search first needs it.
    internal fileprivate(set) lazy var folded: String = name.lowercased()
    /// Child by name, for folders with many children; built when first asked for and kept in step.
    fileprivate var childIndex: [String: TreeNode]?
    /// While `DirectoryTree.attach` links the subfolders of this folder in several turns.
    fileprivate var attaching: Attach?

    /// What `attach` keeps between its turns for one folder.
    fileprivate final class Attach {
        /// Nodes that were there before the new ones: the old children of a folder that is read
        /// again, and the folders made by `node(at:creating:)` since.
        ///
        /// A new node of one of these names is not linked; the node that is there stays (whoever
        /// holds it keeps a live node).
        var known: [String: TreeNode]
        /// A folder that had children is rebuilt: the new list, put in place when it is complete.
        let isMerge: Bool
        var built: [TreeNode] = []
        var seen = Set<String>()
        /// The places of the old nodes in the new list; set when it is put in place (the old list
        /// is still the folder's own until then).
        var places: [(node: TreeNode, index: Int)] = []

        init(known: [String: TreeNode], isMerge: Bool) {
            (self.known, self.isMerge) = (known, isMerge)
        }
    }

    /// Nodes may be made on any thread while they are not part of a tree yet (`DirectoryTree.makeNodes`).
    fileprivate init(name: String, parent: TreeNode?) {
        self.name = name
        self.parent = parent
    }

    /// How deep the folder lies below the root, which is 0.
    public var depth: Int {
        var (depth, node) = (0, parent)
        while let current = node { (depth, node) = (depth + 1, current.parent) }
        return depth
    }

    fileprivate func child(named name: String) -> TreeNode? {
        // Trees are mostly built in order, so the folder asked for is usually the last one.
        if let last = children.last, last.name == name {
            return last
        }
        guard children.count > 8 else {
            return children.first { $0.name == name }
        }
        if childIndex == nil {
            childIndex = Dictionary(children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return childIndex?[name]
    }
}

/// The folders below one root, as far as they are known.
///
/// The tree is filled level by level while a scan runs, or all at once from the cache.
///
/// **Threading.** Not synchronized: a tree is built on one thread and may then be handed to
/// another (the window builds a cached tree in the background and shows it on the main thread).
public final class DirectoryTree {
    public let rootURL: URL
    public let root: TreeNode
    /// The number of folders below the root.
    public private(set) var count = 0
    /// Changes with every change of the tree; a result found for one revision holds only for it.
    private var revision = 0
    /// A search text that matched nothing anywhere, and the revision it was tried on.
    private var failedSearch: (text: String, revision: Int)?

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
        for path in paths { _ = node(at: path, creating: true) }
        if complete { markScanned(root) }
        for path in unscanned { node(at: path)?.isScanned = false }
    }

    private func markScanned(_ node: TreeNode) {
        node.isScanned = true
        node.children.forEach(markScanned)
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

    public func url(of node: TreeNode) -> URL {
        Self.components(of: relativePath(of: node)).reduce(rootURL) { $0.appending(name: $1) }
    }

    /// The path of `url` relative to the root; nil when it is not the root or below it.
    public func relativePath(of url: URL) -> String? {
        Self.relativePath(of: url, below: rootURL)
    }

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

    /// The names of a relative path, cut at the `/` byte.
    ///
    /// (Not at the character `/`: a folder whose name begins with a combining mark would make `/`
    /// and the mark one character.).
    internal static func components(of path: String) -> [String] {
        path.utf8.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
    }

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
            for index in position..<parent.children.count { parent.children[index].indexInParent = index }
        } else {
            node.indexInParent = parent.children.count
            parent.children.append(node)
        }
        parent.childIndex?[name] = node
        // A read of this folder is going on in turns: it meets the node when it gets to the name.
        parent.attaching?.known[name] = node
        count += 1
        revision += 1
        return node
    }

    // MARK: Filling

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
            let known = Dictionary(node.children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let wanted = Set(names)
            for child in node.children where !wanted.contains(child.name) { count -= 1 + folderCount(below: child) }
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
        node.childIndex = nil
        node.attaching = nil
        node.isScanned = true
        return node
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
                known: Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }),
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
            if start == 0 { node.children.reserveCapacity(nodes.count) }
            for fresh in nodes[start..<end] where attach.known[fresh.name] == nil {
                fresh.parent = node
                fresh.indexInParent = node.children.count
                node.children.append(fresh)
                count += 1
            }
        }
        node.childIndex = nil
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
            node.childIndex = nil
            node.isScanned = true
        }
        if attach.isMerge {
            // What was there and is not in the new list has vanished.
            for (name, child) in attach.known where !attach.seen.contains(name) {
                count -= 1 + folderCount(below: child)
            }
            for (known, index) in attach.places { known.indexInParent = index }
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
            if attach.known[fresh.name] != nil { used.insert(fresh.name) }
            child.indexInParent = kept.count
            kept.append(child)
        }
        for (name, child) in attach.known where !used.contains(name) { count -= 1 + folderCount(below: child) }
        node.children = kept
    }

    private func folderCount(below node: TreeNode) -> Int {
        node.children.reduce(0) { $0 + 1 + folderCount(below: $1) }
    }

    /// Every folder below the root as a relative path, parents before their children: the
    /// form the cache stores.
    public var paths: [String] {
        var paths: [String] = []
        paths.reserveCapacity(count)
        func walk(_ node: TreeNode, _ prefix: String) {
            for child in node.children {
                let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
                paths.append(path)
                walk(child, path)
            }
        }
        walk(root, "")
        return paths
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

    private func deepestLast(_ node: TreeNode) -> TreeNode {
        var current = node
        while let last = current.children.last { current = last }
        return current
    }

    /// How far a quick search has come: it found a folder, found none in the whole tree, or
    /// used up its time and goes on from `node` with `remaining` folders still to look at.
    public enum SearchProgress {
        case found(TreeNode)
        case none
        case pending(node: TreeNode, remaining: Int)
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

        case .none, .pending:
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
        timeBudget: TimeInterval?
    ) -> SearchProgress {
        let pattern = TreeQuickSearch(typed)
        guard !pattern.isEmpty, count > 0 else {
            return .none
        }
        // A start that matched nothing anywhere is matched by no longer start either.
        if let failed = failedSearch, failed.revision == revision, !pattern.hasWildcards,
            pattern.text.hasPrefix(failed.text)
        {
            return .none
        }
        let start = start ?? root
        var node = includingStart ? start : neighbour(of: start, forward: forward)
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
        if !pattern.hasWildcards { failedSearch = (pattern.text, revision) }
        return .none
    }
}

/// What is typed into the quick-search field of the tree: the start of a folder's name, with
/// `*` and `?` as wildcards (`*test` finds names containing "test").
///
/// Case is ignored.
public struct TreeQuickSearch {
    private let pattern: String
    internal let hasWildcards: Bool
    /// The typed text in lower case.
    internal var text: String { hasWildcards ? String(pattern.dropLast()) : pattern }

    public init(_ typed: String) {
        let typed = typed.lowercased()
        hasWildcards = typed.contains("*") || typed.contains("?")
        pattern = hasWildcards ? typed + "*" : typed
    }

    public var isEmpty: Bool { pattern.isEmpty }

    public func matches(_ name: String) -> Bool {
        matches(folded: name.lowercased())
    }

    /// For a name that is in lower case already.
    internal func matches(folded name: String) -> Bool {
        hasWildcards ? fnmatch(pattern, name, 0) == 0 : name.hasPrefix(pattern)
    }
}

/// Which tree a directory belongs to.
///
/// On the Mac every disk hangs below `/`, so the tree of a folder on another volume starts at that
/// volume, not at the start-up disk's root.
public enum TreeRoots {
    /// The disks among `places` and `providerRoot`, without doubles: what the tree window offers.
    public static func choices(places: [Place], providerRoot: URL) -> [Place] {
        var choices: [Place] = []
        let disks = places.filter { $0.kind == .internalDisk || $0.kind == .externalDisk || $0.kind == .home }
        for place in [Place(name: "", url: providerRoot, kind: .internalDisk)] + disks
        where !choices.contains(where: { $0.url.isSameLocation(as: place.url) }) {
            choices.append(place)
        }
        // The root's own entry from the places carries its name.
        if let named = disks.first(where: { $0.url.isSameLocation(as: providerRoot) }) { choices[0] = named }
        return choices
    }

    /// The root for the tree of `directory`: the deepest disk that holds it, else the root of
    /// its file system.
    public static func root(for directory: URL, places: [Place], providerRoot: URL) -> URL {
        let disks = places.filter { $0.kind == .internalDisk || $0.kind == .externalDisk }.map(\.url)
        let holding = disks.filter { directory.isSameLocation(as: $0) || directory.isInside($0) }
        return holding.max { $0.locationKey.count < $1.locationKey.count } ?? providerRoot
    }
}

/// Reads the folders below a root (spec 12 › Reading the tree and the tree cache).
///
/// The scan is a background job that must not get in the way: it runs its disk reads at the
/// lowest priority, does not make the system fetch files that are only in the cloud, and
/// does not go into places the user has not opened: other volumes, network automounts, the
/// folders macOS asks the user's permission for, and the cloud folders. Those are listed in
/// the tree and read when the user opens them. A scan ends by itself after `timeLimit`
/// seconds or `folderLimit` folders, and then counts as incomplete.
///
/// **Threading.** `run` blocks and is meant for a background thread. It goes through the tree
/// level by level and reads the folders of a level on all cores at once; `receive` is called
/// on the calling thread, one call at a time. `cancellation` may be set from any thread.
/// `paths` and `unscanned` belong to the thread that runs the scan and are read after `run`
/// has returned.
///
/// Used by one thread at a time: the limits are set before `run`, and `paths`, `unscanned`
/// and `reachedLimit` are only touched by the thread that runs it. The threads that read
/// folders side by side use only what is fixed in `init`, and `cancellation`, which is safe
/// from any thread.
public final class TreeScanner: @unchecked Sendable {
    /// A folder that was read: its path relative to the root and the names of its subfolders,
    /// in display order (sorted off the main thread, where the scan runs).
    public struct Level: Equatable {
        public let path: String
        public let children: [String]
        public let isSorted: Bool
        /// The nodes for `children`, made where the level is made (off the main thread, in a
        /// scan) so that the tree only has to link them.
        public let nodes: [TreeNode]

        public init(path: String, children: [String], isSorted: Bool = false) {
            self.path = path
            self.children = children
            self.isSorted = isSorted
            nodes = DirectoryTree.makeNodes(children, sorted: isSorted)
        }

        public static func == (first: Self, second: Self) -> Bool {
            (first.path, first.children, first.isSorted) == (second.path, second.children, second.isSorted)
        }
    }

    public let cancellation = CancellationFlag()
    /// How long a scan may go on, and how many folders it may find.
    public var timeLimit: TimeInterval = 10 * 60
    public var folderLimit = 5_000_000
    /// True when the last `run` ended because of `timeLimit` or `folderLimit`.
    public private(set) var reachedLimit = false
    private let root: URL
    private let provider: any FileSystemProvider
    private let showHidden: Bool
    private let isExcluded: @Sendable (URL) -> Bool
    /// How many folders are read before their results are handed over.
    private let batchSize: Int
    /// Every folder found so far as a relative path, parents before their children: the form
    /// the cache stores.
    public private(set) var paths: [String] = []
    /// The folders among `paths` that were not read: left out on purpose, or not reached
    /// before the scan was cancelled.
    public private(set) var unscanned: [String] = []

    /// Folders for which `isExcluded` answers true are listed in the tree but not read (other
    /// volumes mounted inside this one).
    ///
    /// Folders on the local disk that are a mount point themselves are left unread as well,
    /// whatever `isExcluded` says. It is called on several threads at once.
    public init(
        root: URL,
        provider: any FileSystemProvider,
        showHidden: Bool = false,
        batchSize: Int = 256,
        isExcluded: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) {
        self.root = root
        self.provider = provider
        self.showHidden = showHidden
        self.batchSize = max(batchSize, 1)
        self.isExcluded = isExcluded
    }

    /// Reads the whole tree, the folders near the root first.
    ///
    /// Returns false when it was cancelled. Links to folders are listed nowhere, so the walk cannot
    /// run in circles; packages (`.app`) are files to the user and are left out as well. A folder
    /// that cannot be read counts as empty.
    @discardableResult
    public func run(receive: ([Level]) -> Void) -> Bool {
        var frontier: [(path: String, url: URL)] = [("", root)]
        paths = []
        unscanned = []
        reachedLimit = false
        let deadline = Date().addingTimeInterval(timeLimit)
        while !frontier.isEmpty {
            var next: [(path: String, url: URL)] = []
            for start in stride(from: 0, to: frontier.count, by: batchSize) {
                if !reachedLimit, paths.count >= folderLimit || Date() > deadline { reachedLimit = true }
                if cancellation.isCancelled || reachedLimit {
                    return cancelled(frontier[start...], next)
                }
                let batch = Array(frontier[start..<min(start + batchSize, frontier.count)])
                let listed = readFolders(batch)
                if cancellation.isCancelled {
                    return cancelled(frontier[start...], next)
                }
                receive(zip(batch, listed).map { Level(path: $0.path, children: $1.map(\.name), isSorted: true) })
                for (folder, children) in zip(batch, listed) {
                    for child in children {
                        let path = folder.path.isEmpty ? child.name : folder.path + "/" + child.name
                        paths.append(path)
                        if child.isMount || child.isUnread || isExcluded(child.url) {
                            unscanned.append(path)
                        } else {
                            next.append((path, child.url))
                        }
                    }
                }
            }
            frontier = next
        }
        return true
    }

    /// The subfolders of a batch of folders, read side by side.
    ///
    /// On the local disk this is done with the threads of the caller's own priority (the scan runs
    /// at utility priority, and so does the disk work of these threads); a file system that may
    /// wait for a server uses the pool, which adds threads while some wait.
    private func readFolders(_ batch: [(path: String, url: URL)]) -> [[Subfolder]] {
        @Sendable
        func read(_ folder: (path: String, url: URL)) -> [Subfolder] {
            Self.gently { Sorter.sorted(folders(of: folder.url, isScan: true), numeric: true, byName: \.name) }
        }
        guard provider.scheme == "file", root.isFileURL else {
            return Parallel.map(batch, read)
        }
        /// Each piece writes its own place.
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<[Subfolder]>.allocate(capacity: batch.count)
        results.initialize(repeating: [])
        defer {
            // The lists that were read are let go before the memory they are in.
            _ = results.deinitialize()
            results.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: batch.count) { index in
            autoreleasepool { results[index] = read(batch[index]) }
        }
        return Array(results)
    }

    private func cancelled(_ unread: ArraySlice<(path: String, url: URL)>, _ found: [(path: String, url: URL)]) -> Bool
    {
        unscanned += unread.dropFirst(unread.first?.path.isEmpty == true ? 1 : 0).map(\.path) + found.map(\.path)
        return false
    }

    /// Folders in the order the tree shows them.
    public static func sorted(_ folders: [(name: String, url: URL)]) -> [(name: String, url: URL)] {
        Sorter.sorted(folders, numeric: true, byName: \.name)
    }

    /// One level, for a folder the user opens before the scan has reached it.
    public func subfolders(of directory: URL) -> [(name: String, url: URL)] {
        folders(of: directory).map { ($0.name, $0.url) }
    }

    private struct Subfolder {
        let name: String
        let url: URL
        /// Another volume is mounted on this folder.
        var isMount = false
        /// A scan does not go in: the folder is protected or only in the cloud (see `isProtected`).
        var isUnread = false
    }

    /// Where a scan does not go on its own: the folders macOS asks the user's permission for
    /// and the cloud folders, in the home folder, and the automounts.
    ///
    /// Whole paths.
    private static let protectedPaths: Set<String> = {
        let home = NSHomeDirectory()
        var paths: Set<String> = [
            "/net", "/home", "/Network", "/dev", "/System/Volumes", "/Volumes", "/private/var/db"
        ]
        for relative in [
            "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library/Mobile Documents",
            "Library/CloudStorage", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers",
            "Library/Group Containers", "Library/Calendars", "Library/Cookies", "Library/HomeKit", "Library/Metadata",
            "Library/Suggestions", "Library/Reminders", "Library/Application Support/AddressBook",
            "Library/Application Support/CallHistoryDB", "Library/Application Support/CallHistoryTransactions",
            "Library/Application Support/FileProvider", "Library/Application Support/CloudDocs",
            "Library/Application Support/com.apple.TCC", "Library/Application Support/Knowledge"
        ] {
            paths.insert(home + "/" + relative)
        }
        return paths
    }()

    /// Whether a scan leaves this folder unread.
    internal static func isProtected(_ url: URL) -> Bool {
        url.isFileURL && protectedPaths.contains(url.path)
    }

    /// Runs `body` with the disk work of this thread at the lowest priority, as far as the
    /// system lets a thread do that (not a pool thread of Dispatch, which then runs at its
    /// quality-of-service class's priority), and without the system fetching a file or folder
    /// that is only in the cloud, which a listing would do.
    internal static func gently<T>(_ body: () -> T) -> T {
        let (disk, cloud) = (
            getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD),
            getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        )
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
        defer {
            // The threads are shared: they go back to what they had.
            if disk >= 0 { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, disk) }
            if cloud >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, cloud) }
        }
        return body()
    }

    /// `isScan`: the folders are read for the scan, which does not go into protected ones; a
    /// folder the user opens is read whatever it is.
    private func folders(of directory: URL, isScan: Bool = false) -> [Subfolder] {
        // The local disk is read entry by entry, and given up at the first entry after a cancellation.
        if directory.isFileURL, provider.scheme == "file" {
            return leanSubfolders(of: directory, isScan: isScan)
        }
        guard !cancellation.isCancelled else {
            return []
        }
        // Read piece by piece, so a huge or slow folder can be given up half-way.
        var items: [FileItem] = []
        let finished: Void? = try? provider.list(directory, showHidden: showHidden) { batch in
            items += batch
            return !cancellation.isCancelled
        }
        guard finished != nil, !cancellation.isCancelled else {
            return []
        }
        // A name with a line break could not be written to the cache file, one with a slash
        // not into a relative path.
        return
            items.filter {
                $0.isRealDirectory && !$0.isPackage && !$0.name.utf8.contains(0x0A) && !$0.name.utf8.contains(0x2F)
            }
            .map { Subfolder(name: $0.name, url: $0.url) }
    }

    /// The same for a folder of the local disk, without a `FileItem` for every file: only the
    /// folders are asked about.
    ///
    /// Hidden folders and packages are left out as a listing leaves them out. A folder that cannot
    /// be opened counts as empty.
    private func leanSubfolders(of directory: URL, isScan: Bool) -> [Subfolder] {
        guard let stream = opendir(directory.path) else {
            return []
        }
        defer { closedir(stream) }
        // The folder's own device; should it not be told, every subfolder is asked whether it is a mount point.
        var own = stat()
        _ = fstat(dirfd(stream), &own)
        var folders: [Subfolder] = []
        while let entry = readdir(stream) {
            if cancellation.isCancelled {
                return []
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name != ".", name != "..", !name.contains("\n") else { continue }
            let url = directory.appending(name: name)
            var info = stat()
            var isMount = false
            var isUnread = false
            switch Int32(entry.pointee.d_type) {
            case DT_DIR:
                // Only a flag of the folder can still hide it; it is looked at when hidden folders are not wanted.
                if !showHidden, name.hasPrefix(".") { continue }
                let known = lstat(url.path, &info) == 0
                if !showHidden {
                    guard known, info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                }
                isMount = known && info.st_dev != own.st_dev && Self.isMountPoint(url.path)
                // A folder that is only in the cloud (SF_DATALESS) would be fetched by a listing.
                isUnread =
                    isScan && (Self.isProtected(url) || (known && info.st_flags & Self.dataless != 0))

            case DT_UNKNOWN:
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                if !showHidden, name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                isUnread = isScan && (Self.isProtected(url) || info.st_flags & Self.dataless != 0)

            default:
                continue
            }
            // Only a folder with an extension can be a package.
            if !url.pathExtension.isEmpty, (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                continue
            }
            folders.append(Subfolder(name: name, url: url, isMount: isMount, isUnread: isUnread))
        }
        return folders
    }

    /// The flag of a folder or file whose content is in the cloud only (`SF_DATALESS`).
    private static let dataless: UInt32 = 0x4000_0000

    /// True when a disk is mounted at `path` itself.
    ///
    /// A device other than the parent's is not enough to say so: the user's folders on the start-up
    /// disk are firmlinked from the data volume, and the system answers with the volume's mount
    /// point for them, not their own.
    internal static func isMountPoint(_ path: String) -> Bool {
        // The system names the mount point by its real path; a path without one is none.
        guard let pointer = realpath(path, nil) else {
            return false
        }
        let real = String(cString: pointer)
        free(pointer)
        var info = statfs()
        return statfs(real, &info) == 0 && mountPoint(info) == real
    }

    /// Where the volume a `statfs` answer describes is mounted.
    private static func mountPoint(_ info: statfs) -> String {
        var info = info
        return withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
