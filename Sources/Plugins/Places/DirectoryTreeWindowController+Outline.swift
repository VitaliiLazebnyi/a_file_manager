import AFMKernel
import AppKit

/// The outline's data source and delegate: the root as the one row at the top, the folders below it.
extension DirectoryTreeWindowController {
    /// One row, the root, at the top; below a folder, its known subfolders.
    internal func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else {
            return tree == nil ? 0 : 1
        }
        return node.children.count
    }

    /// The root at the top; below a folder, its subfolder at `index`.
    internal func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else {
            return tree?.root as Any
        }
        return node.children[index]
    }

    /// A folder can be opened when it has subfolders, or when it was not read yet.
    internal func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode).map { !$0.children.isEmpty || !$0.isScanned } == true
    }

    /// The cell of a row: the folder's name, or the path of the root.
    internal func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
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

    /// The cursor moved: the path below the tree follows it.
    internal func outlineViewSelectionDidChange(_: Notification) {
        updatePath()
    }
}
