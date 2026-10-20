import AFMContracts
import AFMKernel
import AppKit

/// The parts of a panel as they are put together when its view is made (spec 03 › Panel anatomy).
extension PanelViewController {
    /// The drive line: the drive button with the volume list, the free space, and the buttons
    /// for the root and the parent folder.
    internal func makeDriveLine() -> NSView {
        volumeButton.bezelStyle = .recessed
        volumeButton.addItem(withTitle: "/")
        volumeButton.menu?.delegate = self
        volumeButton.setContentHuggingPriority(.required, for: .horizontal)
        volumeButton.setAccessibilityLabel("Volume")
        freeLabel.font = .systemFont(ofSize: 11)
        freeLabel.textColor = .secondaryLabelColor
        freeLabel.lineBreakMode = .byTruncatingTail
        freeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let driveLine = NSStackView(views: [
            volumeButton, freeLabel, spacer, smallButton("/", .goToRoot), smallButton("..", .goToParent)
        ])
        driveLine.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        driveLine.spacing = 6
        return driveLine
    }

    /// What the tab strip and the path bar do: their clicks are this panel's commands.
    internal func connectBars() {
        tabBar.onSelect = { [weak self] index in self?.performFocused(.activateTab, .index(index)) }
        tabBar.onClose = { [weak self] index in self?.performFocused(.closeTab, .index(index)) }
        tabBar.onNewTab = { [weak self] in self?.performFocused(.newTab, .nothing) }
        tabBar.onMove = { [weak self] from, destination in self?.moveTab(from: from, to: destination) }
        tabBar.menuProvider = { [weak self] index in self?.tabMenu(forTab: index) }
        pathBar.onClick = { [weak self] clicks in self?.pathBarClicked(clicks) }
        pathBar.onNavigate = { [weak self] location in self?.performFocused(.changeDirectory, .location(location)) }
        pathBar.menuProvider = { [weak self] in self?.pathMenu() }
        pathBar.onEject = { [weak self] in self?.ejectClicked() }
    }

    /// The table of the Full view: its columns, its looks, and the panel as its data source,
    /// delegate and drag source.
    internal func setUpTable() {
        for column in FileListColumn.fullView {
            let tableColumn = column.makeTableColumn()
            if let width = columnWidths[column.rawValue] {
                tableColumn.width = CGFloat(width)
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.panel = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("File list")
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.style = .plain
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        // Finding a file by typing is the panel's own (`typeToFind`): the table's would ask
        // for the name of every row, on the main thread, for each key.
        tableView.allowsTypeSelect = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.registerForDraggedTypes(PanelDrop.acceptedTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
    }

    /// The place of the list: the table of the Full view and the grid of the other views in
    /// the same spot, one of them hidden.
    internal func makeListArea() -> NSView {
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.contentView.postsBoundsChangedNotifications = true
        tableScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableScrolled),
            name: NSView.boundsDidChangeNotification,
            object: tableScroll.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fitColumns),
            name: NSView.frameDidChangeNotification,
            object: tableScroll.contentView
        )
        let gridScroll = NSScrollView()
        gridView.panel = self
        gridView.registerForDraggedTypes(PanelDrop.acceptedTypes)
        // A list, like the table of the Full view; its cells are its children
        // (`FileGridView.updateAccessibilityCells`).
        gridView.setAccessibilityElement(true)
        gridView.setAccessibilityRole(.list)
        gridView.setAccessibilityLabel("File list")
        gridScroll.documentView = gridView
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.backgroundColor = .textBackgroundColor
        sortHeader.onClick = { [weak self] column in self?.headerClicked(column) }
        sortHeader.menuProvider = { [weak self] in self?.filledHeaderMenu() }
        gridBox.orientation = .vertical
        gridBox.spacing = 0
        gridBox.alignment = .leading
        gridBox.addArrangedSubview(sortHeader)
        gridBox.addArrangedSubview(gridScroll)
        sortHeader.widthAnchor.constraint(equalTo: gridBox.widthAnchor).isActive = true
        gridScroll.widthAnchor.constraint(equalTo: gridBox.widthAnchor).isActive = true
        let area = NSView()
        for part in [tableScroll, gridBox] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            area.addSubview(part)
            NSLayoutConstraint.activate([
                part.topAnchor.constraint(equalTo: area.topAnchor),
                part.bottomAnchor.constraint(equalTo: area.bottomAnchor),
                part.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                part.trailingAnchor.constraint(equalTo: area.trailingAnchor)
            ])
        }
        return area
    }

    /// The status line: the figures of the list and the busy indicator.
    internal func makeStatusLine() -> NSView {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isDisplayedWhenStopped = false
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusLine = NSStackView(views: [statusLabel, statusSpacer, activityIndicator])
        statusLine.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        return statusLine
    }

    /// A click on the path bar makes the panel the source; a double click edits the path.
    internal func pathBarClicked(_ clicks: Int) {
        focus()
        if clicks == 2 {
            commands.perform(.editPath, .nothing)
        }
    }

    /// The eject button of the path bar: ejects the drive the folder is on.
    internal func ejectClicked() {
        guard let volume = host?.ejectableVolume(containing: model.directory) else {
            return
        }
        performFocused(.ejectVolume, .location(volume.url))
    }

    /// A drive-line button that runs a command in this panel.
    private func smallButton(_ title: String, _ command: CommandID) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(driveLineButtonPressed(_:)))
        button.bezelStyle = .recessed
        button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        button.refusesFirstResponder = true
        button.setAccessibilityLabel(command == .goToRoot ? "Root folder" : "Parent folder")
        return button
    }

    /// A drive-line button was pressed: its command runs in this panel.
    @objc
    private func driveLineButtonPressed(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue {
            performFocused(CommandID(rawValue: name), .nothing)
        }
    }

    /// The table shows other rows: the values of plugin columns that wait for rows that went
    /// out of sight are no longer wanted, so they do not hold up those that are.
    @objc
    private func tableScrolled() {
        guard columnValues.hasWaiting, !showsGrid else {
            return
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        let names = Set(
            (visible.location..<(visible.location + visible.length)).compactMap { model.item(atRow: $0)?.name }
        )
        columnValues.dropWaiting(except: names)
    }

    /// The list area changed its size: the Name column takes what the other columns leave.
    ///
    /// So the table fits the panel and no column lies partly outside it, down to the Name column's
    /// least width. The table resizes its first column by itself only once it fits.
    @objc
    internal func fitColumns() {
        let spacing = tableView.intercellSpacing.width
        let spare = tableScroll.contentView.bounds.width - tableView.tableColumns.reduce(0) { $0 + $1.width + spacing }
        // The first column is the Name column.
        for name in tableView.tableColumns.prefix(1) {
            name.width = max(name.minWidth, name.width + spare)
        }
    }
}
