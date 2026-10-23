import AppKit

/// Layout: the paths, the options, the Show buttons, the result list and the footer.
extension SyncWindowController {
    /// Builds the window's content.
    internal func buildContent(in window: NSWindow) {
        let paths = makePathsRow()
        let options = makeOptionsRow()
        let showRow = makeShowRow()
        let scroll = makeList()
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let footer = NSStackView(views: [statusLabel, NSView(), progressBar])

        let stack = NSStackView(views: [paths, options, showRow, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        for part in [paths, options, showRow, scroll, footer] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
    }

    /// The saved sets, the two directories with their folder buttons, and the masks between them.
    private func makePathsRow() -> NSStackView {
        setsButton.addItem(withTitle: "★")
        setsButton.menu?.delegate = self
        setsButton.toolTip = "Saved directories and settings (F2)"
        maskField.placeholderString = "*.*  (exclude after |)"
        maskField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        for field in [leftField, rightField, maskField, offsetField] {
            field.target = self
            field.action = #selector(compareFromField)
        }
        func picker(_ action: Selector) -> NSButton {
            let button = NSButton(title: ">>", target: self, action: action)
            button.toolTip = "Choose a folder"
            return button
        }
        let paths = NSStackView(views: [
            setsButton, leftField, picker(#selector(pickLeft)), maskField, rightField, picker(#selector(pickRight))
        ])
        leftField.widthAnchor.constraint(equalTo: rightField.widthAnchor).isActive = true
        return paths
    }

    /// Compare, the compare options, Synchronize and Close.
    private func makeOptionsRow() -> NSStackView {
        compareButton.target = self
        compareButton.action = #selector(compareOrAbort)
        compareButton.keyEquivalent = "\r"
        synchronizeButton.target = self
        synchronizeButton.action = #selector(synchronize)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        for box in [
            subdirsBox, byContentBox, ignoreDateBox, asymmetricBox, emptyDirectoriesBox, onlySelectedBox, oneHourBox
        ] {
            box.target = self
            box.action = #selector(optionChanged)
        }
        return NSStackView(views: [
            compareButton, subdirsBox, byContentBox, ignoreDateBox, asymmetricBox, emptyDirectoriesBox,
            onlySelectedBox, NSView(), synchronizeButton, closeButton
        ])
    }

    /// The Show buttons, the subdirectory indicator, and the time options.
    private func makeShowRow() -> NSStackView {
        offsetField.widthAnchor.constraint(equalToConstant: 36).isActive = true
        offsetField.toolTip = "Hours added to the dates of the right side (a server in another time zone)"
        tolerancePopup.addItems(withTitles: ["exact dates", "±2 s (FAT)", "±3 s"])
        tolerancePopup.target = self
        tolerancePopup.action = #selector(optionChanged)
        showButtons = [
            showButton("→", .copyToRight, tip: "Files to copy to the right (Ctrl+Shift+L)"),
            showButton("=", .equal, tip: "Equal files (Ctrl+Shift+E)"),
            showButton("≠", .notEqual, tip: "Different files (Ctrl+Shift+N)"),
            showButton("←", .copyToLeft, tip: "Files to copy to the left, or to delete on the right (Ctrl+Shift+R)"),
            showButton("duplicates", .duplicates, tip: "Files on both sides (Ctrl+Shift+D)"),
            showButton("singles", .singles, tip: "Files on one side only (Ctrl+Shift+S)")
        ]
        indicatorLabel.textColor = .secondaryLabelColor
        indicatorLabel.lineBreakMode = .byTruncatingMiddle
        indicatorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return NSStackView(
            views: [NSTextField(labelWithString: "Show:")] + showButtons.map(\.button)
                + [
                    indicatorLabel, NSView(), tolerancePopup, oneHourBox, NSTextField(labelWithString: "dT="),
                    offsetField,
                    NSTextField(labelWithString: "h")
                ]
        )
    }

    /// A Show button that stands for `part` of the filter.
    private func showButton(_ title: String, _ part: SyncShow, tip: String) -> (button: NSButton, part: SyncShow) {
        let button = NSButton(title: title, target: self, action: #selector(showChanged))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.toolTip = tip
        return (button, part)
    }

    /// The result list in its scroll view, with its columns, clicks, keys and context menu.
    private func makeList() -> NSScrollView {
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 36
            tableColumn.headerCell.alignment =
                column.id.hasSuffix("Size") ? .right : (column.id == "action" ? .center : .left)
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.style = .plain
        table.allowsMultipleSelection = true
        table.floatsGroupRows = false
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.onKey = { [weak self] event in self?.handleKey(event) == true }
        rowMenu.delegate = self
        table.menu = rowMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }
}
