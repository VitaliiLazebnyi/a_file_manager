import AFMKernel
import AppKit

/// Where the cells of the Brief and Thumbnails views are (spec 03 › Brief, 03 › Thumbnails).
/// Cells are numbered like the rows of the panel model. Pure arithmetic: every cell has the
/// same size, so nothing here depends on how many entries the folder has.
struct GridGeometry: Equatable {
    enum Flow: Equatable {
        /// Brief: the cells fill a column from top to bottom, then the next column to the
        /// right; the list scrolls sideways.
        case columns
        /// Thumbnails: the cells fill a row from left to right, then the next row; the list
        /// scrolls up and down.
        case rows
    }

    enum Direction {
        case left, right, up, down
    }

    let flow: Flow
    let count: Int
    let cell: CGSize
    /// The size of the visible part of the list.
    let viewport: CGSize

    /// Cells in a column (Brief) or in a row (Thumbnails).
    var perLine: Int {
        switch flow {
        case .columns: return max(1, Int(viewport.height / max(cell.height, 1)))
        case .rows: return max(1, Int(viewport.width / max(cell.width, 1)))
        }
    }

    /// Columns (Brief) or rows (Thumbnails).
    var lines: Int { (count + perLine - 1) / perLine }

    var contentSize: CGSize {
        switch flow {
        case .columns: return CGSize(width: max(CGFloat(lines) * cell.width, viewport.width), height: viewport.height)
        case .rows: return CGSize(width: viewport.width, height: max(CGFloat(lines) * cell.height, viewport.height))
        }
    }

    /// The position of a cell: which line it is in, and where in that line.
    private func place(of index: Int) -> (line: Int, offset: Int) { (index / perLine, index % perLine) }

    func frame(of index: Int) -> CGRect {
        let (line, offset) = place(of: index)
        switch flow {
        case .columns:
            return CGRect(
                x: CGFloat(line) * cell.width, y: CGFloat(offset) * cell.height, width: cell.width, height: cell.height
            )

        case .rows:
            return CGRect(
                x: CGFloat(offset) * cell.width, y: CGFloat(line) * cell.height, width: cell.width, height: cell.height
            )
        }
    }

    /// The cell at a point; nil on empty space.
    func index(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let (across, along) = (Int(point.x / cell.width), Int(point.y / cell.height))
        let (line, offset) = flow == .columns ? (across, along) : (along, across)
        guard offset < perLine else { return nil }
        let index = line * perLine + offset
        return index < count ? index : nil
    }

    /// The cells that may touch a rectangle, for drawing: all cells of the lines it crosses.
    func indexes(in rect: CGRect) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let (start, end) =
            flow == .columns
            ? (rect.minX / cell.width, rect.maxX / cell.width) : (rect.minY / cell.height, rect.maxY / cell.height)
        let first = min(max(Int(start.rounded(.down)), 0), lines)
        let last = min(max(Int(end.rounded(.up)), first), lines)
        return min(first * perLine, count)..<min(last * perLine, count)
    }

    /// Where an arrow key takes the cursor. In Brief, ← and → jump a column and stop at the
    /// first and the last entry (spec 03 › Brief); in Thumbnails, ↑ and ↓ jump a row.
    func index(from index: Int, moving direction: Direction) -> Int {
        guard count > 0 else { return 0 }
        let step: Int
        switch (flow, direction) {
        case (.columns, .up), (.rows, .left): step = -1
        case (.columns, .down), (.rows, .right): step = 1
        case (.columns, .left), (.rows, .up): step = -perLine
        case (.columns, .right), (.rows, .down): step = perLine
        }
        let target = index + step
        if flow == .rows, abs(step) > 1, !(0..<count).contains(target) {
            // No tile straight above or below: the cursor stays, except on the way down into a
            // last row that is shorter, where it goes to the last tile.
            return step > 0 && place(of: index).line < lines - 1 ? count - 1 : index
        }
        return max(0, min(target, count - 1))
    }

    /// The cells one Page Up or Page Down passes.
    var pageSize: Int {
        let visibleLines =
            flow == .columns ? Int(viewport.width / max(cell.width, 1)) : Int(viewport.height / max(cell.height, 1))
        return max(1, max(1, visibleLines) * perLine - (flow == .columns ? 1 : 0))
    }
}

/// Finds a file by typing the start of its name, as the table of the Full view does by itself
/// (spec 03 › Quick search, "Letter only"). What was typed is forgotten after a pause.
struct TypeSelect {
    static let pause: TimeInterval = 1
    private(set) var prefix = ""
    private var lastKey: TimeInterval = 0

    /// Adds a typed character and returns what to look for.
    mutating func add(_ characters: String, at time: TimeInterval) -> String {
        if time - lastKey > Self.pause { prefix = "" }
        lastKey = time
        prefix += characters
        return prefix
    }

    /// The row to go to: the next name that starts with `prefix`, from the cursor on, around
    /// the end of the list. A longer prefix may stay on the row it is on; a single letter
    /// moves on to the next name with that letter.
    static func row(matching prefix: String, in names: [String], from cursor: Int) -> Int? {
        row(matching: prefix, count: names.count, from: cursor) { names[$0] }
    }

    /// The same for a list that is not copied into an array of names: `name` gives the name of
    /// the entry at an index.
    static func row(matching prefix: String, count: Int, from cursor: Int, name: (Int) -> String) -> Int? {
        guard count > 0, !prefix.isEmpty else { return nil }
        let start = prefix.count > 1 ? cursor : cursor + 1
        let matches = matcher(for: prefix)
        for step in 0..<count {
            let row = ((start + step) % count + count) % count
            if matches(name(row)) { return row }
        }
        return nil
    }

    /// The same for the entries of a panel, **for any thread**: a long list is looked through
    /// in the background. Gives up, with nil, once `cancellation` is set.
    static func row(
        matching prefix: String, in items: [FileItem], from cursor: Int, cancellation: CancellationFlag? = nil
    ) -> Int? {
        let count = items.count
        guard count > 0, !prefix.isEmpty else { return nil }
        let start = ((prefix.count > 1 ? cursor : cursor + 1) % count + count) % count
        let matches = matcher(for: prefix)
        return items.withUnsafeBufferPointer { items in
            var row = start
            for step in 0..<count {
                if step & 0xFFF == 0xFFF, cancellation?.isCancelled == true { return nil }
                if matches(items[row].name) { return row }
                row += 1
                if row == count { row = 0 }
            }
            return nil
        }
    }

    /// Whether a name starts with what was typed, upper and lower case being the same. Typed
    /// text is mostly plain ASCII, as most names are: those are compared byte by byte, which
    /// is several times faster than Foundation's comparison (a key looks at every name of the
    /// list when nothing matches). Anything else is left to Foundation.
    static func matcher(for prefix: String) -> (String) -> Bool {
        let needle = Array(prefix.lowercased().utf8)
        let slow: (String) -> Bool = { $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil }
        guard needle.allSatisfy({ $0 < 0x80 }) else { return slow }
        return { name in
            let verdict = name.utf8.withContiguousStorageIfAvailable { bytes -> Bool? in
                guard bytes.count >= needle.count else {
                    // Shorter than what was typed: no match, unless it holds something that folds.
                    return bytes.contains { $0 >= 0x80 } ? nil : false
                }
                for index in needle.indices {
                    let byte = bytes[index]
                    if byte >= 0x80 { return nil }
                    if (byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) != needle[index] { return false }
                }
                // What follows may join the last letter (an accent written after it).
                if bytes.count > needle.count, bytes[needle.count] >= 0x80 { return nil }
                return true
            }
            if let verdict, let known = verdict { return known }
            return slow(name)
        }
    }
}

/// The cursor bar, the same in every view: a light bar with a darker border
/// (spec 03 › Cursor, selection and row states).
enum CursorBar {
    static func draw(in rect: NSRect) {
        let bar = rect.insetBy(dx: 0.5, dy: 0.5)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
        bar.fill()
        NSColor.selectedContentBackgroundColor.setStroke()
        NSBezierPath(rect: bar).stroke()
    }

    /// The frame around a folder the mouse drags files over (spec 05 › Drop targets).
    static func drawDropFrame(in rect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

/// The file list of the Brief and Thumbnails views.
///
/// The view draws its cells itself and has no subview per entry: it draws what is in the
/// rectangle it is asked to draw and nothing else, so a folder with a hundred thousand entries
/// costs the same as one with a hundred. Everything it shows comes from the panel's model;
/// clicks and keys go to the panel, which treats them exactly like those of the Full view.
/// Main thread only.
final class FileGridView: NSView, NSDraggingSource, NSUserInterfaceValidations {
    weak var panel: PanelViewController?
    private(set) var geometry = GridGeometry(
        flow: .columns, count: 0, cell: CGSize(width: 100, height: 20), viewport: .zero)
    private var flow = GridGeometry.Flow.columns
    /// The width of the widest of the longest names, measured when the list was last taken from
    /// the model; nil until measured.
    private var widestName: CGFloat?
    /// Where the mouse went down, while a drag may still start from there.
    private var pressed: (point: NSPoint, row: Int)?
    /// The row the mouse drags files over, when it would take them; -1 is the list as a whole.
    var dropRow: Int? {
        didSet { if dropRow != oldValue { needsDisplay = true } }
    }

    static let briefRowHeight: CGFloat = 20
    static let nameFont = NSFont.systemFont(ofSize: 12)
    static let captionFont = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    private var model: PanelModel? { panel?.model }

    // MARK: Layout

    /// The side of a thumbnail tile.
    private var tileSide: CGFloat { panel?.settings.thumbnailSide ?? 96 }

    /// Takes the list from the model again: the entries, their number or the layout changed.
    func reload(flow: GridGeometry.Flow) {
        self.flow = flow
        widestName = nil
        layOut()
        needsDisplay = true
    }

    /// Works out the cells for the size the list has now.
    func layOut() {
        guard let model else { return }
        let viewport = enclosingScrollView?.contentSize ?? bounds.size
        let cell: CGSize
        switch flow {
        case .columns:
            // Measuring the names is a pass over the list; the list only changes in `reload`, while
            // the panel being resized asks for the layout on every step.
            let widest = widestName ?? Self.widestBriefName(in: model.items)
            widestName = widest
            cell = CGSize(
                width: Self.briefColumnWidth(
                    widest: widest, limit: panel?.settings.briefWidthLimit, viewport: viewport.width),
                height: Self.briefRowHeight)

        case .rows:
            cell = CGSize(width: tileSide + 20, height: tileSide + 40)
        }
        let geometry = GridGeometry(flow: flow, count: model.rowCount, cell: cell, viewport: viewport)
        guard geometry != self.geometry || frame.size != geometry.contentSize else { return }
        self.geometry = geometry
        setFrameSize(geometry.contentSize)
        needsDisplay = true
    }

    /// A Brief column is as wide as the longest name, up to the limit and the width of the
    /// panel (spec 03 › Brief). Measuring text is slow, so only the names with the most
    /// characters are measured; finding those is one quick pass over the list.
    static func briefColumnWidth(for items: [FileItem], limit: CGFloat?, viewport: CGFloat) -> CGFloat {
        briefColumnWidth(widest: widestBriefName(in: items), limit: limit, viewport: viewport)
    }

    /// The width of the widest of the longest names of the list, as drawn.
    static func widestBriefName(in items: [FileItem]) -> CGFloat {
        var longest: [(length: Int, name: String)] = []
        var shortestKept = 0
        for item in items {
            let length = item.name.utf16.count
            guard longest.count < 6 || length > shortestKept else { continue }
            longest.append((length, item.name))
            if longest.count > 6 {
                longest.sort { $0.length > $1.length }
                longest.removeLast()
            }
            shortestKept = longest.map(\.length).min() ?? 0
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: nameFont]
        return longest.map { ("[" + $0.name + "]" as NSString).size(withAttributes: attributes).width }.max() ?? 0
    }

    static func briefColumnWidth(widest: CGFloat, limit: CGFloat?, viewport: CGFloat) -> CGFloat {
        // The icon, the gaps around it and a little air to the next column.
        let wanted = ceil(widest) + 16 + 20
        let most = max(80, min(limit ?? .greatestFiniteMagnitude, viewport > 0 ? viewport : .greatestFiniteMagnitude))
        return min(max(wanted, 80), most)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportResized), name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func viewportResized() {
        guard !isHidden, panel?.showsGrid == true else { return }
        layOut()
        panel?.gridDidScroll()
    }

    @objc private func scrolled() {
        guard panel?.showsGrid == true else { return }
        panel?.gridDidScroll()
    }

    /// The rows that are on screen.
    var visibleRows: Range<Int> { geometry.indexes(in: visibleRect) }

    func frame(ofRow row: Int) -> NSRect { geometry.frame(of: row) }

    func row(at point: NSPoint) -> Int { geometry.index(at: point) ?? -1 }

    func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < geometry.count else { return }
        scrollToVisible(geometry.frame(of: row))
    }

    func redraw(row: Int) {
        guard row >= 0, row < geometry.count else { return }
        setNeedsDisplay(geometry.frame(of: row))
    }

    /// Where the name of a row is drawn, for the in-place name editor.
    func nameFrame(ofRow row: Int) -> NSRect {
        let frame = geometry.frame(of: row)
        switch flow {
        case .columns: return NSRect(x: frame.minX + 22, y: frame.minY, width: frame.width - 24, height: frame.height)
        case .rows: return NSRect(x: frame.minX + 2, y: frame.maxY - 36, width: frame.width - 4, height: 20)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let panel, let model else { return }
        if dropRow == -1 { CursorBar.drawDropFrame(in: visibleRect) }
        // Whether a file is asked for its own icon or picture is decided once more for each
        // file, by the volume it is on (`FileListColumn.icon`).
        let ownIcons = model.volume?.isLocal ?? false
        for row in geometry.indexes(in: dirtyRect) {
            let frame = geometry.frame(of: row)
            guard frame.intersects(dirtyRect) else { continue }
            if row == model.cursor, panel.isActive { CursorBar.draw(in: frame) }
            let item = model.item(atRow: row)
            // The name under the rename box is left out.
            let color =
                row == panel.renamingRow
                ? NSColor.clear : panel.nameColor(for: item, selected: model.isSelected(row: row))
            switch flow {
            case .columns: drawBriefCell(item, in: frame, color: color, ownIcons: ownIcons)
            case .rows: drawTile(item, in: frame, color: color, ownIcons: ownIcons)
            }
            if row == dropRow { CursorBar.drawDropFrame(in: frame) }
        }
    }

    private static var parentIcon: NSImage? { FileListColumn.parentIcon }

    private static func paragraph(_ alignment: NSTextAlignment, _ lineBreak: NSLineBreakMode) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        return style
    }

    private static let briefStyle = paragraph(.left, .byTruncatingMiddle)
    private static let captionStyle = paragraph(.center, .byTruncatingMiddle)

    /// The name as the lists write it: folders in brackets (spec 03 › Names, extensions and folders).
    static func caption(for item: FileItem?) -> String {
        guard let item else { return "[..]" }
        return DisplayText.clean(item.isFolder ? "[\(item.name)]" : item.name)
    }

    private func drawBriefCell(_ item: FileItem?, in frame: NSRect, color: NSColor, ownIcons: Bool) {
        let icon = item.map { FileListColumn.icon(for: $0, own: ownIcons) } ?? Self.parentIcon
        icon?.draw(
            in: NSRect(x: frame.minX + 3, y: frame.midY - 8, width: 16, height: 16), from: .zero,
            operation: .sourceOver,
            fraction: item?.isHidden == true ? 0.5 : 1, respectFlipped: true, hints: nil)
        let text = Self.caption(for: item) as NSString
        text.draw(
            with: NSRect(x: frame.minX + 24, y: frame.minY + 2, width: frame.width - 30, height: frame.height - 4),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: Self.nameFont, .foregroundColor: color, .paragraphStyle: Self.briefStyle
            ])
    }

    /// A tile: the picture of the file, or its icon until the picture is there and where a
    /// file has none, and the name below (spec 03 › Thumbnails).
    private func drawTile(_ item: FileItem?, in frame: NSRect, color: NSColor, ownIcons: Bool) {
        let side = tileSide
        let box = NSRect(x: frame.midX - side / 2, y: frame.minY + 4, width: side, height: side)
        var picture: NSImage?
        // Pictures are made of files of local disks only; elsewhere a tile shows the icon of
        // the file's type, which costs no trip to a server.
        if let item, ownIcons, item.url.isFileURL, !item.isFolder, Mounts.isLocal(path: item.url.path) {
            picture = panel?.thumbnails.image(for: item, side: side, scale: window?.backingScaleFactor ?? 2)
        }
        if let picture {
            let scale = min(side / max(picture.size.width, 1), side / max(picture.size.height, 1), 1)
            let size = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
            picture.draw(
                in: NSRect(
                    x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height
                ),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let icon = item.map { FileListColumn.icon(for: $0, own: ownIcons) } ?? Self.parentIcon
            let iconSide = min(side, max(32, side / 2))
            icon?.draw(
                in: NSRect(x: box.midX - iconSide / 2, y: box.midY - iconSide / 2, width: iconSide, height: iconSide),
                from: .zero,
                operation: .sourceOver, fraction: item?.isHidden == true ? 0.5 : 1, respectFlipped: true, hints: nil)
        }
        let text = Self.caption(for: item) as NSString
        text.draw(
            with: NSRect(x: frame.minX + 3, y: box.maxY + 4, width: frame.width - 6, height: 16),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: Self.captionFont, .foregroundColor: color, .paragraphStyle: Self.captionStyle
            ])
    }

    // MARK: Keyboard

    override func becomeFirstResponder() -> Bool {
        panel?.didBecomeFirstResponder()
        return true
    }

    /// Keys that are bound to commands go to the commands. The arrow keys that are bound to
    /// nothing move the cursor, as they do in the table of the Full view, and letters find a
    /// file by typing.
    override func keyDown(with event: NSEvent) {
        guard let panel else {
            super.keyDown(with: event)
            return
        }
        if panel.handleKey(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let directions: [UInt16: GridGeometry.Direction] = [123: .left, 124: .right, 125: .down, 126: .up]
        if modifiers.isEmpty, let direction = directions[event.keyCode] {
            panel.moveCursor(direction)
        } else if modifiers.isDisjoint(with: [.command, .control]), let typed = Self.typedText(of: event) {
            panel.typeToFind(typed, at: event.timestamp)
        } else {
            super.keyDown(with: event)
        }
    }

    /// The characters of a key press that types something; nil for function and control keys.
    static func typedText(of event: NSEvent) -> String? {
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first,
            scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return characters
    }

    // Cmd+A, Cmd+C, Cmd+X and Cmd+V arrive as the standard editing actions (see `EditingRole`).

    override func selectAll(_: Any?) { panel?.perform(.selectAll) }
    @objc func copy(_: Any?) { panel?.perform(.copy) }
    @objc func cut(_: Any?) { panel?.perform(.cut) }
    @objc func paste(_: Any?) { panel?.perform(.paste) }

    // MARK: Mouse

    /// The click under way is a second click on the cursor item (`isRenameClick`).
    private var renameOnRelease = false

    override func mouseDown(with event: NSEvent) {
        let wasFocused = window?.firstResponder === self
        window?.makeFirstResponder(self)
        guard let panel else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        pressed = nil
        renameOnRelease = row >= 0 && panel.isRenameClick(row: row, event: event, wasFocused: wasFocused)
        guard row >= 0 else { return }
        if panel.handleClick(row: row, modifiers: event.modifierFlags) { return }
        panel.clicked(row: row)
        if event.clickCount == 2 {
            panel.commands.perform(.open)
        } else {
            pressed = (point, row)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let panel else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - pressed.point.x) > 4 || abs(point.y - pressed.point.y) > 4 else { return }
        self.pressed = nil
        // The cell is drawn into an image once; only the first few items carry it (a drag of
        // thousands of items shows a handful), the others are dragged without a picture. A drag
        // of very many items is one item on the pasteboard (`PanelDrop.beginDrag`).
        let frame = geometry.frame(of: pressed.row)
        let image = dragImage(ofRow: pressed.row)
        let items = panel.draggingItems(forRow: pressed.row).enumerated().map {
            index, pasteboardItem -> NSDraggingItem in
            let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
            dragged.setDraggingFrame(frame, contents: index < Self.imagedDragItems ? image : nil)
            return dragged
        }
        guard !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: event, source: self)
        PanelDrop.offerFileNames(on: session.draggingPasteboard)
    }

    override func mouseUp(with _: NSEvent) {
        // Still pressed: the mouse was not dragged away.
        if renameOnRelease, let pressed { panel?.scheduleRename(row: pressed.row) }
        renameOnRelease = false
        pressed = nil
    }

    /// How many of the dragged items carry the picture of the cell.
    static let imagedDragItems = 8

    private func dragImage(ofRow row: Int) -> NSImage {
        let frame = geometry.frame(of: row)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: frame) else { return NSImage(size: frame.size) }
        cacheDisplay(in: frame, to: bitmap)
        let image = NSImage(size: frame.size)
        image.addRepresentation(bitmap)
        return image
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return panel?.contextMenu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem, let id = MenuBuilder.command(of: menuItem) {
            return panel?.commands.isEnabled(id) ?? false
        }
        return true
    }

    // MARK: Drag and drop

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext)
        -> NSDragOperation
    {
        [.copy, .move, .generic]
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        PanelDrop.endDrag()
        PanelDrop.endSession()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let panel else { return [] }
        let row = self.row(at: convert(sender.draggingLocation, from: nil))
        let (operation, target) = panel.validateDrop(sender, row: row)
        dropRow = operation.isEmpty ? nil : target
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropRow = nil
        // What was read of another program's drag is not kept while it is elsewhere; the
        // program's own drag stays known until it ends.
        if PanelDrop.current == nil { PanelDrop.endSession(sender?.draggingSequenceNumber) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropRow = nil
        PanelDrop.endSession(sender.draggingSequenceNumber)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropRow = nil
        return panel?.acceptDrop(sender, row: row(at: convert(sender.draggingLocation, from: nil))) ?? false
    }
}

/// The header of the Brief and Thumbnails views: the sort keys as buttons, and nothing else
/// (spec 03 › The header).
final class SortHeaderView: NSView {
    /// Called with the column that was clicked.
    var onClick: ((FileListColumn) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var order = ListOrder() {
        didSet { needsDisplay = true }
    }

    static let columns: [FileListColumn] = [.name, .ext, .size, .date]
    private static let buttonWidth: CGFloat = 76

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    private func frame(of index: Int) -> NSRect {
        NSRect(
            x: CGFloat(index) * Self.buttonWidth, y: 0, width: Self.buttonWidth,
            height: bounds.height)
    }

    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (index, column) in Self.columns.enumerated() {
            let frame = frame(of: index)
            NSRect(x: frame.maxX - 1, y: 4, width: 1, height: frame.height - 8).fill()
            let isSortKey = column.sortKey == order.key
            let title = (isSortKey ? (order.descending ? "↓" : "↑") : "") + column.title
            (title as NSString).draw(
                at: NSPoint(x: frame.minX + 8, y: 4),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: isSortKey ? .semibold : .regular),
                    .foregroundColor: NSColor.headerTextColor
                ])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = Self.columns.indices.first(where: { frame(of: $0).contains(point) }) {
            onClick?(Self.columns[index])
        }
    }

    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
}
