/// One folder of a directory tree (spec 12 › Directory Tree dialog).
///
/// Nodes belong to whoever owns their `DirectoryTree`; only the tree changes them.
public final class TreeNode {
    /// What `attach` keeps between its turns for one folder.
    internal final class Attach {
        /// Nodes that were there before the new ones: the old children of a folder that is read
        /// again, and the folders made by `node(at:creating:)` since.
        ///
        /// A new node of one of these names is not linked; the node that is there stays (whoever
        /// holds it keeps a live node).
        internal var known: [String: TreeNode]
        /// A folder that had children is rebuilt: the new list, put in place when it is complete.
        internal let isMerge: Bool
        /// The new list of a merge so far.
        internal var built: [TreeNode] = []
        /// The names of the known nodes that are in the new list.
        internal var seen = Set<String>()
        /// The places of the old nodes in the new list; set when it is put in place (the old list
        /// is still the folder's own until then).
        internal var places: [(node: TreeNode, index: Int)] = []

        /// The state of a first turn: `known` are the nodes there, `isMerge` says whether the folder had children.
        internal init(known: [String: TreeNode], isMerge: Bool) {
            (self.known, self.isMerge) = (known, isMerge)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The folder's name.
    public let name: String
    /// The folder the node is in; nil for the root, and for a node not yet linked into a tree.
    public internal(set) weak var parent: TreeNode?
    /// The subfolders that are known, in display order.
    public internal(set) var children: [TreeNode] = []
    /// True once the folder has been read: its children are then all there are.
    public internal(set) var isScanned = false
    /// The node's place in `parent.children`, kept up to date wherever the children change, so
    /// that stepping from one folder to the next costs nothing.
    internal var indexInParent = 0
    /// The name in lower case, made when a quick search first needs it.
    internal private(set) lazy var folded: String = name.lowercased()
    /// Child by name, for folders with many children; built when first asked for and kept in step.
    ///
    /// It holds what it should when it has an entry for every child; otherwise (empty after a change of the
    /// children) it is built again when asked.
    internal var childIndex: [String: TreeNode] = [:]
    /// While `DirectoryTree.attach` links the subfolders of this folder in several turns.
    internal var attaching: Attach?

    /// How deep the folder lies below the root, which is 0.
    public var depth: Int {
        var (levels, node) = (0, parent)
        while let current = node {
            (levels, node) = (levels + 1, current.parent)
        }
        return levels
    }

    /// Nodes may be made on any thread while they are not part of a tree yet (`DirectoryTree.makeNodes`).
    internal init(name: String, parent: TreeNode?) {
        self.name = name
        self.parent = parent
    }

    /// The subfolder called `name`; nil when there is none.
    internal func child(named name: String) -> TreeNode? {
        // Trees are mostly built in order, so the folder asked for is usually the last one.
        if let last = children.last, last.name == name {
            return last
        }
        guard children.count > 8 else {
            return children.first { $0.name == name }
        }
        if childIndex.count != children.count {
            childIndex = Dictionary(children.map { ($0.name, $0) }) { first, _ in first }
        }
        return childIndex[name]
    }

    deinit {
        // Nothing to release.
    }
}
