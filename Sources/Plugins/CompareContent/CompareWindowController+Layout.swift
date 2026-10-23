import AFMKernel
import AppKit

/// Layout: the rows of controls, the two panes and their menu.
extension CompareWindowController {
    /// Builds the window's content: the paths, two rows of controls, the panes and the status line.
    internal func buildContent(in window: NSWindow) {
        let paths = makePathsRow()
        let first = makeFirstRow()
        let second = makeSecondRow()
        for box in [binaryBox, caseBox, spacesBox, endingsBox, verticalBox, editBox] {
            box.target = self
            box.action = #selector(optionChanged(_:))
        }
        bytesPopup.target = self
        bytesPopup.action = #selector(optionChanged(_:))

        split.isVertical = !settings.flag(CompareSettingsKey.vertical, default: false)
        split.dividerStyle = .thin
        for table in [leftTable, rightTable] {
            split.addArrangedSubview(makePane(table))
        }

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [paths, first, second, split, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        for part in [paths, first, second, split, statusLabel] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
    }

    /// A button that sends `action` to the controller, with `tip` as its help.
    private func makeButton(_ title: String, _ action: Selector, tip: String) -> NSButton {
        let made = NSButton(title: title, target: self, action: action)
        made.toolTip = tip
        return made
    }

    /// The two path fields, each with its button to choose the file.
    private func makePathsRow() -> NSStackView {
        for field in [leftField, rightField] {
            field.target = self
            field.action = #selector(compare)
            field.lineBreakMode = .byTruncatingHead
        }
        let paths = NSStackView(views: [
            leftField, makeButton(">>", #selector(pickLeft), tip: "Choose the left file"),
            rightField, makeButton(">>", #selector(pickRight), tip: "Choose the right file")
        ])
        leftField.widthAnchor.constraint(equalTo: rightField.widthAnchor).isActive = true
        return paths
    }

    /// Compare, the differences, the font, the search and the binary options.
    private func makeFirstRow() -> NSStackView {
        differenceButtons = [
            makeButton("Next difference", #selector(nextDifference), tip: "Option+Down"),
            makeButton("Previous difference", #selector(previousDifference), tip: "Option+Up")
        ]
        searchField.placeholderString = "Search in both files"
        searchField.target = self
        searchField.action = #selector(searchNext)
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        bytesPopup.addItems(withTitles: CompareSettingsKey.bytesPerLineChoices.map { count in "\(count) bytes" })
        return NSStackView(
            views: [makeButton("Compare", #selector(compare), tip: "")] + differenceButtons
                + [
                    makeButton("Font…", #selector(chooseFont), tip: ""), searchField, NSView(), binaryBox, bytesPopup,
                    verticalBox
                ]
        )
    }

    /// Edit mode with its buttons, Save, Resync, Swap and the text options.
    private func makeSecondRow() -> NSStackView {
        editButtons = [
            makeButton(
                "Copy ->",
                #selector(copyToRight),
                tip: "Copy the difference or the selected lines to the right (Option+Right)"
            ),
            makeButton(
                "Copy <-",
                #selector(copyToLeft),
                tip: "Copy the difference or the selected lines to the left (Option+Left)"
            ),
            makeButton("Undo", #selector(undoEdit), tip: "")
        ]
        saveButton.target = self
        saveButton.action = #selector(save)
        let resync = makeButton(
            "Resync",
            #selector(markResync),
            tip: "Mark the selected line of the pane that has the focus; with a line marked on each side, the two are "
                + "taken to belong together"
        )
        return NSStackView(
            views: [editBox] + editButtons + [
                saveButton, resync, makeButton("Swap", #selector(swapSides), tip: "Swap panels (Ctrl+U)"),
                NSView(), caseBox, spacesBox, endingsBox
            ]
        )
    }

    /// One pane: a table of line numbers and texts in a scroll view whose scrolling the other pane follows.
    private func makePane(_ table: PaneTableView) -> NSScrollView {
        let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("number"))
        number.width = 70
        let text = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        text.width = 600
        table.addTableColumn(number)
        table.addTableColumn(text)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.menu = makeMenu()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        return scroll
    }

    /// The context menu of a pane.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        add("Copy selection to clipboard", #selector(copySelection))
        add("Mark line for resync", #selector(markResync))
        add("Forget resync", #selector(clearResync))
        add("Swap Panels", #selector(swapSides))
        return menu
    }
}
