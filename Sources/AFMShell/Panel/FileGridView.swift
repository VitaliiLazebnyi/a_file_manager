import AFMContracts
import AFMKernel
import AppKit

/// The file list of the Brief and Thumbnails views.
///
/// The view draws its cells itself and has no subview per entry: it draws what is in the
/// rectangle it is asked to draw and nothing else, so a folder with a hundred thousand entries
/// costs the same as one with a hundred. Everything it shows comes from the panel's model;
/// clicks and keys go to the panel, which treats them exactly like those of the Full view.
/// Main thread only.
internal final class FileGridView: NSView, NSDraggingSource, NSUserInterfaceValidations {
    /// How many of the dragged items carry the picture of the cell.
    internal static let imagedDragItems = 8

    /// The panel the list belongs to.
    internal weak var panel: PanelViewController?
    /// Where the cells are, as last laid out.
    internal private(set) var geometry = GridGeometry(
        flow: .columns,
        count: 0,
        cell: CGSize(width: 100, height: 20),
        viewport: .zero
    )
    /// The row the mouse drags files over, when it would take them; -1 is the list as a whole.
    internal var dropRow: Int? {
        didSet {
            if dropRow != oldValue {
                needsDisplay = true
            }
        }
    }

    private var flow = GridGeometry.Flow.columns
    /// The width of the widest of the longest names, measured when the list was last taken from
    /// the model; nil until measured.
    private var widestName: CGFloat?
    /// Where the mouse went down, while a drag may still start from there.
    private var pressed: (point: NSPoint, row: Int)?
    /// The click under way is a second click on the cursor item (`isRenameClick`).
    private var renameOnRelease = false

    /// Drawn from the top down.
    override internal var isFlipped: Bool { true }
    /// Takes the keyboard, like the table of the Full view.
    override internal var acceptsFirstResponder: Bool { true }
    /// Draws only its cells; the scroll view's background shows between them.
    override internal var isOpaque: Bool { false }

    /// The rows that are on screen.
    internal var visibleRows: Range<Int> { geometry.indexes(in: visibleRect) }

    private var model: PanelModel? { panel?.model }

    /// The side of a thumbnail tile.
    private var tileSide: CGFloat { panel?.settings.thumbnailSide ?? 96 }

    // MARK: Layout

    /// Takes the list from the model again: the entries, their number or the layout changed.
    internal func reload(flow: GridGeometry.Flow) {
        self.flow = flow
        widestName = nil
        layOut()
        needsDisplay = true
    }

    /// Works out the cells for the size the list has now.
    internal func layOut() {
        guard let model else {
            return
        }
        let viewport = enclosingScrollView?.contentSize ?? bounds.size
        let cell: CGSize
        switch flow {
        case .columns:
            // Measuring the names is a pass over the list; the list only changes in `reload`, while
            // the panel being resized asks for the layout on every step.
            let widest = widestName ?? GridCellPainter.widestBriefName(in: model.items)
            widestName = widest
            let width = GridCellPainter.briefColumnWidth(
                widest: widest,
                limit: panel?.settings.briefWidthLimit,
                viewport: viewport.width
            )
            cell = CGSize(width: width, height: GridCellPainter.briefRowHeight)

        case .rows:
            cell = CGSize(width: tileSide + 20, height: tileSide + 40)
        }
        let geometry = GridGeometry(flow: flow, count: model.rowCount, cell: cell, viewport: viewport)
        guard geometry != self.geometry || frame.size != geometry.contentSize else {
            return
        }
        self.geometry = geometry
        setFrameSize(geometry.contentSize)
        needsDisplay = true
    }

    /// Follows the size and the scrolling of the clip view the list is put into.
    override internal func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else {
            return
        }
        clip.postsFrameChangedNotifications = true
        clip.postsBoundsChangedNotifications = true
        center.addObserver(
            self,
            selector: #selector(viewportResized),
            name: NSView.frameDidChangeNotification,
            object: clip
        )
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    /// Scrolls the list so that `row` is on screen.
    internal func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < geometry.count else {
            return
        }
        scrollToVisible(geometry.frame(of: row))
    }

    /// Draws the cell of `row` again.
    internal func redraw(row: Int) {
        guard row >= 0, row < geometry.count else {
            return
        }
        setNeedsDisplay(geometry.frame(of: row))
    }

    /// The row at a point of the list; -1 on empty space.
    internal func row(at point: NSPoint) -> Int {
        geometry.index(at: point) ?? -1
    }

    /// Where the name of a row is drawn, for the in-place name editor.
    internal func nameFrame(ofRow row: Int) -> NSRect {
        let frame = geometry.frame(of: row)
        switch flow {
        case .columns:
            return NSRect(x: frame.minX + 22, y: frame.minY, width: frame.width - 24, height: frame.height)

        case .rows:
            return NSRect(x: frame.minX + 2, y: frame.maxY - 36, width: frame.width - 4, height: 20)
        }
    }

    // MARK: Drawing

    /// The cells in `dirtyRect`: the cursor bar, the icon or picture and the name, and the frame
    /// of a drop.
    override internal func draw(_ dirtyRect: NSRect) {
        guard let panel, let model else {
            return
        }
        if dropRow == -1 {
            CursorBar.drawDropFrame(in: visibleRect)
        }
        // Whether a file is asked for its own icon or picture is decided once more for each
        // file, by the volume it is on (`FileListColumn.icon`).
        let ownIcons = model.volume?.isLocal ?? false
        for row in geometry.indexes(in: dirtyRect) {
            let frame = geometry.frame(of: row)
            guard frame.intersects(dirtyRect) else {
                continue
            }
            if row == model.cursor, panel.isActive {
                CursorBar.draw(in: frame)
            }
            let item = model.item(atRow: row)
            // The name under the rename box is left out.
            let color =
                row == panel.renamingRow
                ? NSColor.clear : panel.nameColor(for: item, selected: model.isSelected(row: row))
            let cell = RowLook(item: item, color: color, ownIcons: ownIcons)
            switch flow {
            case .columns:
                GridCellPainter.drawBriefCell(cell, in: frame)

            case .rows:
                GridCellPainter.drawTile(
                    cell,
                    in: frame,
                    side: tileSide,
                    picture: picture(of: item, ownIcons: ownIcons)
                )
            }
            if row == dropRow {
                CursorBar.drawDropFrame(in: frame)
            }
        }
    }

    // MARK: Keyboard

    /// The list takes the keyboard: its panel becomes the source.
    override internal func becomeFirstResponder() -> Bool {
        panel?.didBecomeFirstResponder()
        return true
    }

    /// Keys that are bound to commands go to the commands.
    ///
    /// The arrow keys that are bound to nothing move the cursor, as they do in the table of the
    /// Full view, and letters find a file by typing.
    override internal func keyDown(with event: NSEvent) {
        guard let panel, panel.handleListKey(event, arrowsMoveCursor: true) else {
            super.keyDown(with: event)
            return
        }
    }

    /// Cmd+A arrives as the standard editing action: the panel's Select All command.
    override internal func selectAll(_: Any?) {
        panel?.perform(.selectAll)
    }

    // MARK: Mouse

    /// A click marks with Cmd or Shift, moves the cursor otherwise; a double click opens.
    ///
    /// A press may become a drag, and a second, unhurried click on the cursor's row a rename.
    override internal func mouseDown(with event: NSEvent) {
        let wasFocused = window?.firstResponder === self
        window?.makeFirstResponder(self)
        guard let panel else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        pressed = nil
        renameOnRelease = row >= 0 && panel.isRenameClick(row: row, event: event, wasFocused: wasFocused)
        guard row >= 0, !panel.handleClick(row: row, modifiers: event.modifierFlags) else {
            return
        }
        panel.clicked(row: row)
        if event.clickCount == 2 {
            panel.commands.perform(.open)
        } else {
            pressed = (point, row)
        }
    }

    /// A press that moves more than a few points starts a drag of the row (and of the marked
    /// items with it, when the row is marked).
    override internal func mouseDragged(with event: NSEvent) {
        guard let pressed, let panel else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - pressed.point.x) > 4 || abs(point.y - pressed.point.y) > 4 else {
            return
        }
        self.pressed = nil
        // The cell is drawn into an image once; only the first few items carry it (a drag of
        // thousands of items shows a handful), the others are dragged without a picture. A drag
        // of very many items is one item on the pasteboard (`PanelDrop.beginDrag`).
        let frame = geometry.frame(of: pressed.row)
        let image = dragImage(ofRow: pressed.row)
        let items = panel.draggingItems(forRow: pressed.row).enumerated()
            .map { index, pasteboardItem -> NSDraggingItem in
                let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
                dragged.setDraggingFrame(frame, contents: index < Self.imagedDragItems ? image : nil)
                return dragged
            }
        guard !items.isEmpty else {
            return
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        PanelDrop.offerFileNames(on: session.draggingPasteboard)
    }

    /// The button is up: a second click on the cursor's row that was not dragged renames, once
    /// the double-click time has passed.
    override internal func mouseUp(with _: NSEvent) {
        // Still pressed: the mouse was not dragged away.
        if renameOnRelease, let pressed {
            panel?.scheduleRename(row: pressed.row, after: NSEvent.doubleClickInterval)
        }
        renameOnRelease = false
        pressed = nil
    }

    /// The context menu of the row under the mouse.
    override internal func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return panel?.contextMenu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    /// A command's menu item can be chosen while its command can run; other items always.
    internal func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let id = PanelViewController.command(of: item) else {
            return true
        }
        return panel?.commands.isEnabled(id) ?? false
    }

    // MARK: Drag and drop

    /// What a drag that starts in the list allows, inside the program and outside.
    internal func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext)
        -> NSDragOperation
    {
        [.copy, .move, .generic]
    }

    /// The drag that started here is over, wherever it ended.
    internal func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        PanelDrop.endDrag()
        PanelDrop.endSession(nil)
    }

    /// A drag comes over the list: as when it moves over it.
    override internal func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    /// A drag moves over the list: what a drop on the row under the mouse would do, with that
    /// row framed.
    override internal func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let panel else {
            return []
        }
        let row = row(at: convert(sender.draggingLocation, from: nil))
        let (operation, target) = panel.validateDrop(sender, row: row)
        dropRow = operation.isEmpty ? nil : target
        return operation
    }

    /// The drag has left the list.
    override internal func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropRow = nil
        PanelDrop.dragLeft(sender)
    }

    /// The drag is over.
    override internal func draggingEnded(_ sender: any NSDraggingInfo) {
        dropRow = nil
        PanelDrop.endSession(sender.draggingSequenceNumber)
    }

    /// Something was dropped on the row under the mouse.
    override internal func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropRow = nil
        return panel?.acceptDrop(sender, row: row(at: convert(sender.draggingLocation, from: nil))) ?? false
    }

    /// The picture of a file of a local disk, from the panel's store; nil until it is there,
    /// and for anything else, which shows the icon of its type and costs no trip to a server.
    private func picture(of item: FileItem?, ownIcons: Bool) -> NSImage? {
        guard let item, ownIcons, item.url.isFileURL, !item.isFolder, Mounts.isLocal(path: item.url.path) else {
            return nil
        }
        return panel?.thumbnails.image(for: item, side: tileSide, scale: window?.backingScaleFactor ?? 2)
    }

    /// The cell of `row` as an image, for a drag.
    private func dragImage(ofRow row: Int) -> NSImage {
        let frame = geometry.frame(of: row)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: frame) else {
            return NSImage(size: frame.size)
        }
        cacheDisplay(in: frame, to: bitmap)
        let image = NSImage(size: frame.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// The list was resized: the cells are laid out anew.
    @objc
    private func viewportResized() {
        guard !isHidden, panel?.showsGrid == true else {
            return
        }
        layOut()
        panel?.gridDidScroll()
    }

    /// The list was scrolled: the panel hears of the rows on screen now.
    @objc
    private func scrolled() {
        guard panel?.showsGrid == true else {
            return
        }
        panel?.gridDidScroll()
    }

    deinit {
        // Nothing to release: the notification center forgets the list when it goes.
    }
}
