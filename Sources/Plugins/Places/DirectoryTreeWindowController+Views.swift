import AFMShell
import AppKit

/// The views of the tree window, and their layout.
extension DirectoryTreeWindowController {
    /// The outline of the folders, which hands the keys it is sent to `onKey` first.
    internal final class TreeOutlineView: NSOutlineView {
        /// Handles a key; true when it was used, otherwise the outline handles it.
        internal var onKey: ((NSEvent) -> Bool)?

        /// Offers the key to `onKey`, then to the outline.
        override internal func keyDown(with event: NSEvent) {
            if onKey?(event) != true {
                super.keyDown(with: event)
            }
        }

        /// Option-click on a disclosure triangle (and Option-Right) open a folder and everything
        /// below it: on a disk that is every row at once and a reader for each folder that has
        /// not been read.
        ///
        /// A folder opens one level.
        override internal func expandItem(_ item: Any?, expandChildren _: Bool) {
            super.expandItem(item, expandChildren: false)
        }
    }

    /// The window, where the rescan keys work wherever the focus is (spec 12 › Controls and keys).
    internal final class TreeWindow: ToolWindow {
        /// Reads the tree again.
        internal var onRescanKey: (() -> Void)?

        /// F2 and Ctrl+R rescan; any other key goes its usual way.
        override internal func keyDown(with event: NSEvent) {
            if DirectoryTreeWindowController.isRescanKey(event) {
                onRescanKey?()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Lays out the disks, the outline, the path, the quick search and the buttons in `window`.
    internal func buildContent(in window: NSWindow) {
        rootPopup.target = self
        rootPopup.action = #selector(rootChosen)
        setUpOutline()
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

    /// The outline's one column, its looks, and the controller as its data source, delegate and target.
    private func setUpOutline() {
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
    }
}
