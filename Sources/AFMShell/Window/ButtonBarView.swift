import AFMContracts
import AFMKernel
import AppKit

/// The look the buttons of the bars share: flat, framed only under the mouse, drawn pressed
/// while their state is on (spec 02 › Horizontal button bar: appearance).
enum BarButton {
    static let height: CGFloat = 24

    /// Settings key of the size of the button bar's pictures: an index into `iconSizes`.
    static let iconSizeKey = "window.buttonBarIconSize"
    static let iconSizeNames = ["Small", "Medium", "Large", "Extra large"]
    /// Point sizes of the pictures; the buttons grow with them.
    static let iconSizes: [CGFloat] = [13, 20, 28, 36]
    static let defaultIconSize = 2

    static func iconSize(from settings: SettingsStore) -> CGFloat {
        iconSizes[min(max(settings.index(iconSizeKey, default: defaultIconSize), 0), iconSizes.count - 1)]
    }

    static func make(target: AnyObject, action: Selector) -> NSButton {
        style(NSButton(title: "", target: target, action: action))
    }

    static func style<Button: NSButton>(_ button: Button) -> Button {
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.showsBorderOnlyWhileMouseInside = true
        button.refusesFirstResponder = true
        button.font = .systemFont(ofSize: 11)
        return button
    }

    static func separator() -> NSView {
        let line = NSBox(frame: NSRect(x: 0, y: 0, width: 5, height: height))
        line.boxType = .separator
        return line
    }
}

/// A button of the button bar. It draws its own frame, a rounded square over the whole button
/// (the system's bezels keep a fixed height, a strip lower than a large picture): grey under
/// the mouse, darker while pressed, in the accent colour while its command is on. A ⌘-press is
/// handed to the bar, which may start a drag, instead of pressing the button.
final class BarCommandButton: NSButton {
    var onCommandMouseDown: ((NSEvent) -> Void)?
    /// The area that tells of the mouse coming and going. Only this one is replaced: the
    /// others belong to AppKit (the tool tip's among them).
    private var hoverArea: NSTrackingArea?
    private var isMouseInside = false {
        didSet { if isMouseInside != oldValue { needsDisplay = true } }
    }

    override var state: NSControl.StateValue {
        didSet { contentTintColor = state == .on ? .white : nil }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandMouseDown else {
            super.mouseDown(with: event)
            return
        }
        onCommandMouseDown(event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        if let window {
            isMouseInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with _: NSEvent) { isMouseInside = true }
    override func mouseExited(with _: NSEvent) { isMouseInside = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if state == .on {
            fill = NSColor.controlAccentColor.withAlphaComponent(isEnabled ? (isHighlighted ? 0.8 : 1) : 0.4)
        } else if isEnabled, isHighlighted {
            fill = NSColor.labelColor.withAlphaComponent(0.2)
        } else if isEnabled, isMouseInside {
            fill = NSColor.labelColor.withAlphaComponent(0.1)
        } else {
            fill = nil
        }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// The line in front of a group of the button bar: it separates the group from the one before
/// it and is the handle by which the group is dragged.
final class BarSeparatorView: NSView {
    static let width: CGFloat = 9
    var onMouseDown: ((NSEvent) -> Void)?

    override func draw(_: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: floor(bounds.midX), y: 3, width: 1, height: max(bounds.height - 6, 0)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let onMouseDown else {
            super.mouseDown(with: event)
            return
        }
        onMouseDown(event)
    }

    override func resetCursorRects() {
        if onMouseDown != nil { addCursorRect(bounds, cursor: .openHand) }
    }
}

/// The button bar above the panels (spec 02 › Button bars): one button for each command the
/// plugins proposed, or the user's own layout once there is one (`ToolbarRegistry`). The bar
/// knows no command itself. Main thread only.
///
/// The user arranges the bar by dragging: ⌘-drag moves a button (into another group, onto a
/// group's handle for a group of its own, off the bar to remove it), and dragging the handle
/// in front of a group moves the whole group. A group may start a line of its own: while
/// something is dragged an empty line shows below the bar to drop it in. Lines left empty
/// disappear. Every change is stored as the user's layout at once.
final class ButtonBarView: NSView, NSDraggingSource {
    private let kernel: Kernel
    private let flow = FlowView()
    private(set) var buttons: [NSButton] = []
    /// What the bar shows, in order; nil is a separator, `ToolbarRegistry.lineBreak` starts a line.
    private(set) var entries: [CommandID?] = []

    /// What an item of the bar stands for in the arrangement.
    enum Slot: Equatable {
        case button(line: Int, group: Int, index: Int)
        /// The handle in front of a group, which is also the separator between two groups.
        case handle(line: Int, group: Int)

        var line: Int {
            switch self {
            case .button(let line, _, _), .handle(let line, _): return line
            }
        }
    }

    /// What is being dragged: a button or a whole group.
    enum Dragged: Equatable {
        case button(line: Int, group: Int, index: Int)
        case group(line: Int, group: Int)
    }

    /// Where a drop would put what is dragged.
    enum DropTarget: Equatable {
        case button(ButtonBarArrangement.Target)
        case group(ButtonBarArrangement.Place)
    }

    private(set) var slots: [Slot] = []
    private var dragged: Dragged?
    private let indicator = NSView()
    private static let pasteboardType = NSPasteboard.PasteboardType("com.afilemanager.button-bar-item")
    /// How far from a handle's middle a dropped button still makes a group of its own.
    private static let handleSnap: CGFloat = 6

    /// The commands offered by a right click on the bar, when a plugin provides them
    /// (spec 05 › Horizontal button bar); the visibility switches are the shell's own.
    static let contextCommands: [CommandID?] = [
        .changeButtonBar, .configuration, .resetButtonBar, nil, .showButtonBar, .showDriveButtons, .showCommandLine,
        .showFunctionKeys
    ]

    init(kernel: Kernel) {
        self.kernel = kernel
        super.init(frame: .zero)
        flow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)
        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: topAnchor), flow.bottomAnchor.constraint(equalTo: bottomAnchor),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        addSubview(indicator)
        registerForDraggedTypes([Self.pasteboardType])
        rebuild()
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    /// The layout without what cannot be shown: buttons whose command no plugin registered are
    /// left out, and so are the separators and line breaks that would then stand at an end,
    /// side by side, or around an empty line.
    static func entries(of layout: [ToolbarRegistry.Button?], commands: CommandRegistry) -> [ToolbarRegistry.Button?] {
        let shown = layout.filter {
            $0.map { $0.command == ToolbarRegistry.lineBreak || commands[$0.command] != nil } ?? true
        }
        var buttons = shown.compactMap { $0 }.filter { $0.command != ToolbarRegistry.lineBreak }.makeIterator()
        return ButtonBarArrangement(entries: shown.map { $0?.command }).entries.map { id in
            guard let id else { return nil }
            return id == ToolbarRegistry.lineBreak ? ToolbarRegistry.Button(command: id, symbol: "") : buttons.next()
        }
    }

    /// The command's title and its main key, `Find Files… (⌥F7)`, and below them what the
    /// button does, when its plugin says.
    static func toolTip(for command: Command, keys: KeyBindings, hint: String? = nil) -> String {
        let title =
            keys.shortcuts(for: command.id).first.map { "\(command.title) (\($0.displayText))" } ?? command.title
        return hint.map { "\(title)\n\($0)" } ?? title
    }

    /// Draws the bar again from the registry; called when the layout changed.
    func rebuild() {
        let layout = Self.entries(of: kernel.toolbar.layout(from: kernel.settings), commands: kernel.commands)
        entries = layout.map { $0?.command }
        buttons = []
        slots = []
        let iconSize = BarButton.iconSize(from: kernel.settings)
        let side = max(BarButton.height, iconSize + 14)
        let pictures = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        var items: [NSView] = []
        var lineBreaks: Set<Int> = []
        var (line, group, index) = (0, 0, 0)
        func addHandle() {
            let handle = BarSeparatorView(frame: NSRect(x: 0, y: 0, width: BarSeparatorView.width, height: side))
            let dragged = Dragged.group(line: line, group: group)
            handle.onMouseDown = { [weak self, weak handle] event in
                guard let self, let handle else { return }
                trackDrag(dragged, of: handle, from: event)
            }
            slots.append(.handle(line: line, group: group))
            items.append(handle)
        }
        if !layout.isEmpty { addHandle() }
        for entry in layout {
            guard let entry else {
                (group, index) = (group + 1, 0)
                addHandle()
                continue
            }
            if entry.command == ToolbarRegistry.lineBreak {
                (line, group, index) = (line + 1, 0, 0)
                lineBreaks.insert(items.count)
                addHandle()
                continue
            }
            guard let command = kernel.commands[entry.command] else { continue }
            let button = BarButton.style(
                BarCommandButton(title: "", target: self, action: #selector(buttonPressed(_:))))
            button.isBordered = false
            let dragged = Dragged.button(line: line, group: group, index: index)
            button.onCommandMouseDown = { [weak self, weak button] event in
                guard let self, let button else { return }
                if !trackDrag(dragged, of: button, from: event) { buttonPressed(button) }
            }
            slots.append(.button(line: line, group: group, index: index))
            index += 1
            if let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: command.title) {
                button.image = image.withSymbolConfiguration(pictures) ?? image
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
                // Square, so that the frame shown under the mouse is a square too.
                button.frame.size = NSSize(width: side, height: side)
            } else {
                // A symbol this system does not have: the button carries the command's name.
                button.title = command.title
                button.sizeToFit()
                button.frame.size.height = side
            }
            button.identifier = NSUserInterfaceItemIdentifier(command.id.rawValue)
            button.toolTip = Self.toolTip(
                for: command, keys: kernel.keyBindings, hint: kernel.toolbar.hint(for: command.id))
            button.setAccessibilityLabel(command.title)
            buttons.append(button)
            items.append(button)
        }
        flow.lineBreaks = lineBreaks
        flow.items = items
        validate()
    }

    /// Makes the buttons follow what their commands say: available or not, pressed or not.
    func validate() {
        for button in buttons {
            guard let name = button.identifier?.rawValue else { continue }
            let id = CommandID(rawValue: name)
            let isEnabled = kernel.commands.isEnabled(id)
            let state: NSControl.StateValue = kernel.commands.isChecked(id) ? .on : .off
            if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
            if button.state != state { button.state = state }
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { kernel.commands.perform(CommandID(rawValue: name)) }
        // The click itself toggled the button; what it shows is up to the command.
        validate()
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        let menu = MenuBuilder.menu("", Self.contextCommands, commands: kernel.commands, keys: nil)
        return menu.items.isEmpty ? nil : menu
    }

    // MARK: Arranging

    /// Applies a drop and stores the result as the user's layout (which redraws the bar).
    func apply(_ dragged: Dragged, to target: DropTarget?) {
        var arrangement = ButtonBarArrangement(entries: entries)
        switch (dragged, target) {
        case (.button(let line, let group, let index), .button(let to)):
            arrangement.moveButton(line: line, group: group, index: index, to: to)

        case (.button(let line, let group, let index), nil):
            arrangement.removeButton(line: line, group: group, index: index)

        case (.group(let line, let group), .group(let place)):
            arrangement.moveGroup(line: line, group: group, to: place)

        default: return
        }
        guard arrangement.entries != entries else { return }
        kernel.toolbar.setLayout(arrangement.entries, in: kernel.settings)
    }

    /// Waits for the mouse to move a few points before a drag starts, so that a press that
    /// does not move stays a press. Answers whether a drag was started.
    @discardableResult
    private func trackDrag(_ item: Dragged, of _: NSView, from event: NSEvent) -> Bool {
        guard let window else { return false }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return false }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                beginDrag(item, from: next)
                return true
            }
        }
        return false
    }

    /// The views a drag of `item` takes along: the button, or the handle and its group.
    private func views(of item: Dragged) -> [NSView] {
        zip(flow.items, slots).compactMap { view, slot in
            switch (item, slot) {
            case (.button(let l, let g, let i), .button(let line, let group, let index)):
                return (l, g, i) == (line, group, index) ? view : nil

            case (.group(let l, let g), .handle(let line, let group)),
                (.group(let l, let g), .button(let line, let group, _)):
                return (l, g) == (line, group) ? view : nil

            default: return nil
            }
        }
    }

    private func beginDrag(_ item: Dragged, from event: NSEvent) {
        let views = views(of: item)
        guard let first = views.first else { return }
        let image = Self.picture(of: views)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("", forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            NSRect(origin: convert(first.frame, from: flow).origin, size: image.size), contents: image)
        dragged = item
        views.forEach { $0.alphaValue = 0.3 }
        // Room for a new line below the bar while the drag lasts.
        flow.extraHeight = (flow.items.first?.frame.height ?? BarButton.height) + 2
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        // A button dropped off the bar is removed: it does not fly back.
        if case .button = item { session.animatesToStartingPositionsOnCancelOrFail = false }
    }

    /// The views side by side, as the drag shows them.
    private static func picture(of views: [NSView]) -> NSImage {
        let reps = views.compactMap { view -> NSBitmapImageRep? in
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        let size = NSSize(width: views.reduce(0) { $0 + $1.frame.width }, height: views.map(\.frame.height).max() ?? 0)
        return NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (view, rep) in zip(views, reps) {
                rep.draw(in: NSRect(x: x, y: 0, width: view.frame.width, height: view.frame.height))
                x += view.frame.width
            }
            return true
        }
    }

    /// Whether item `index` is the last of its line.
    private func endsLine(_ index: Int) -> Bool {
        index == slots.count - 1 || slots[index + 1].line != slots[index].line
    }

    /// Where a drop at `point` (in the bar's coordinates) would put `item`.
    func dropTarget(for item: Dragged, at point: NSPoint) -> DropTarget? {
        let point = flow.convert(point, from: self)
        let frames = flow.items.map(\.frame)
        guard let bottom = frames.map(\.maxY).max() else { return nil }
        let lines = ButtonBarArrangement(entries: entries).lines
        // Below the last row: a line of its own.
        if point.y > bottom + 2 {
            let place = ButtonBarArrangement.Place.newLine(at: lines.count)
            if case .group = item { return .group(place) }
            return .button(.newGroup(place))
        }
        switch item {
        case .group:
            // The nearest handle, or the end of a line.
            var anchors: [(place: ButtonBarArrangement.Place, point: NSPoint)] = []
            for (index, (slot, frame)) in zip(slots, frames).enumerated() {
                if case .handle(let line, let group) = slot {
                    anchors.append((.line(line, at: group), NSPoint(x: frame.midX, y: frame.midY)))
                }
                if endsLine(index) {
                    anchors.append(
                        (.line(slot.line, at: lines[slot.line].count), NSPoint(x: frame.maxX, y: frame.midY)))
                }
            }
            func distance(_ anchor: NSPoint) -> CGFloat { hypot(anchor.x - point.x, 3 * (anchor.y - point.y)) }
            return anchors.min { distance($0.point) < distance($1.point) }.map { .group($0.place) }

        case .button:
            // The row under the mouse, or the nearest one.
            func distance(to frame: NSRect) -> CGFloat {
                frame.minY > point.y ? frame.minY - point.y : max(point.y - frame.maxY, 0)
            }
            guard let nearest = frames.min(by: { distance(to: $0) < distance(to: $1) }) else { return nil }
            let inRow = frames.indices.filter { frames[$0].minY == nearest.minY }
            for index in inRow {
                if case .handle(let line, let group) = slots[index],
                    abs(point.x - frames[index].midX) <= Self.handleSnap
                {
                    return .button(.newGroup(.line(line, at: group)))
                }
            }
            guard let last = inRow.last else { return nil }
            if endsLine(last), point.x > frames[last].maxX + frames[last].width / 2 {
                return .button(.newGroup(.line(slots[last].line, at: lines[slots[last].line].count)))
            }
            let index = inRow.first { frames[$0].maxX > point.x } ?? last
            let before = point.x < frames[index].midX
            switch slots[index] {
            case .button(let line, let group, let position):
                return .button(.inGroup(line: line, group: group, at: before ? position : position + 1))

            case .handle(let line, let group):
                if before, group > 0 {
                    return .button(.inGroup(line: line, group: group - 1, at: lines[line][group - 1].count))
                }
                return .button(.inGroup(line: line, group: group, at: 0))
            }
        }
    }

    /// Where the bar shows that a drop would go, in the flow's coordinates: a thin line between
    /// two buttons, a wider mark where a group would stand, a band below the bar for a new line.
    private func indicatorFrame(for target: DropTarget) -> NSRect? {
        let frames = flow.items.map(\.frame)
        func frame(of wanted: Slot) -> NSRect? { zip(slots, frames).first { $0.0 == wanted }?.1 }
        func mark(atX x: CGFloat, around frame: NSRect, width: CGFloat) -> NSRect {
            NSRect(x: x - width / 2, y: frame.minY + 2, width: width, height: frame.height - 4)
        }
        func place(_ place: ButtonBarArrangement.Place, width: CGFloat) -> NSRect? {
            switch place {
            case .line(let line, let group):
                if let handle = frame(of: .handle(line: line, group: group)) {
                    return mark(atX: handle.midX, around: handle, width: width)
                }
                guard let last = slots.lastIndex(where: { $0.line == line }) else { return nil }
                return mark(atX: frames[last].maxX + 2, around: frames[last], width: width)

            case .newLine:
                guard let first = frames.first, let bottom = frames.map(\.maxY).max() else { return nil }
                return NSRect(
                    x: first.minX, y: bottom + 4, width: max(flow.bounds.width - 2 * first.minX, 0),
                    height: first.height - 4)
            }
        }
        switch target {
        case .group(let target): return place(target, width: 3)
        case .button(.newGroup(let target)): return place(target, width: 7)

        case .button(.inGroup(let line, let group, let at)):
            if let next = frame(of: .button(line: line, group: group, index: at)) {
                return mark(atX: next.minX - 1, around: next, width: 2)
            }
            if let previous = frame(of: .button(line: line, group: group, index: at - 1)) {
                return mark(atX: previous.maxX + 1, around: previous, width: 2)
            }
            return nil
        }
    }

    private func showIndicator(for target: DropTarget?) {
        guard let target, let frame = indicatorFrame(for: target) else {
            indicator.isHidden = true
            return
        }
        indicator.frame = convert(frame, from: flow)
        var alpha: CGFloat = 1
        switch target {
        case .group(.newLine), .button(.newGroup(.newLine)): alpha = 0.25
        case .button(.newGroup): alpha = 0.45
        default: break
        }
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
        indicator.isHidden = false
    }

    private func isOurs(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? ButtonBarView) === self && dragged != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isOurs(sender), let dragged else { return [] }
        showIndicator(for: dropTarget(for: dragged, at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    override func draggingExited(_: NSDraggingInfo?) { indicator.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        guard isOurs(sender), let item = dragged else { return false }
        dragged = nil
        guard let target = dropTarget(for: item, at: convert(sender.draggingLocation, from: nil)) else { return false }
        apply(item, to: target)
        return true
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        indicator.isHidden = true
        flow.items.forEach { $0.alphaValue = 1 }
        // The bar as it was during the drag, with the room for a new line.
        let bar = window.map { $0.convertToScreen(convert(bounds, to: nil)) }
        flow.extraHeight = 0
        guard let item = dragged else { return }
        dragged = nil
        // A button let go of away from the bar is taken off it; Escape takes nothing off.
        let cancelled = NSApp.currentEvent?.type == .keyDown
        guard case .button = item, operation.isEmpty, !cancelled, let bar else { return }
        if !bar.insetBy(dx: -4, dy: -4).contains(screenPoint) { apply(item, to: nil) }
    }
}

/// The drive button bar (spec 02 › Drive button bar): one button for every place and volume
/// the file systems offer. A click shows the place in the source panel, Shift+click in a new
/// folder tab. A drive that can be ejected has an eject button next to it. Hidden until the
/// user switches it on, as in Total Commander. Main thread only.
final class DriveBarView: NSView {
    private let kernel: Kernel
    private let store: PlacesStore
    private let flow = FlowView()
    private(set) var buttons: [NSButton] = []
    /// The eject buttons, by the index of their place.
    private(set) var ejectButtons: [Int: NSButton] = [:]
    private(set) var places: [Place] = []

    init(kernel: Kernel, places store: PlacesStore) {
        self.kernel = kernel
        self.store = store
        super.init(frame: .zero)
        flow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)
        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: topAnchor), flow.bottomAnchor.constraint(equalTo: bottomAnchor),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        // Volumes come and go, and the file systems answer in their own time: the bar follows the store.
        store.observe { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    private static func symbol(for kind: Place.Kind) -> String {
        switch kind {
        case .home: return "house"
        case .folder: return "folder"
        case .internalDisk: return "internaldrive"
        case .externalDisk: return "externaldrive"
        }
    }

    /// Shows the places the file systems have answered with (`PlacesStore`, which asks them in
    /// the background: nothing here waits for a file system).
    func rebuild() {
        places = store.all
        ejectButtons = [:]
        buttons = places.enumerated().map { index, place in
            let button = BarButton.make(target: self, action: #selector(buttonPressed(_:)))
            button.title = DisplayText.clean(place.name)
            button.image = NSImage(
                systemSymbolName: Self.symbol(for: place.kind), accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.tag = index
            button.toolTip = DisplayText.clean(kernel.fileSystems.displayPath(place.url))
            button.sizeToFit()
            button.frame.size.height = BarButton.height
            return button
        }
        var items: [NSView] = []
        for (index, button) in buttons.enumerated() {
            items.append(button)
            guard places[index].canBeEjected else { continue }
            let eject = BarButton.style(BarCommandButton(title: "", target: self, action: #selector(ejectPressed(_:))))
            eject.isBordered = false
            eject.setButtonType(.momentaryPushIn)
            eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            eject.imagePosition = .imageOnly
            eject.tag = index
            let title = "Eject “\(DisplayText.clean(places[index].name))”"
            eject.toolTip = title
            eject.setAccessibilityLabel(title)
            eject.frame.size = NSSize(width: 18, height: BarButton.height)
            ejectButtons[index] = eject
            items.append(eject)
        }
        flow.items = items
        validate()
    }

    @objc private func ejectPressed(_ sender: NSButton) {
        guard places.indices.contains(sender.tag) else { return }
        kernel.commands.perform(.ejectVolume, .location(places[sender.tag].url))
    }

    /// The place the source panel is in: the one with the longest path that contains its folder.
    static func currentPlace(among places: [Place], for directory: URL) -> Int? {
        let path = directory.standardized.path
        let candidates = places.enumerated().filter { _, place in
            guard place.url.scheme == directory.scheme, place.url.host == directory.host else { return false }
            let root = place.url.standardized.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        return candidates.max { $0.element.url.path.count < $1.element.url.path.count }?.offset
    }

    /// Presses the button of the place the source panel shows, and greys the bar out while
    /// the panel cannot go anywhere (a job is running).
    func validate() {
        let isEnabled = kernel.commands.isEnabled(.changeDirectory)
        let current = Self.currentPlace(among: places, for: kernel.panels.source.model.directory)
        for (index, button) in buttons.enumerated() {
            let state: NSControl.StateValue = index == current ? .on : .off
            if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
            if button.state != state { button.state = state }
        }
        let canEject = kernel.commands.isEnabled(.ejectVolume)
        for button in ejectButtons.values where button.isEnabled != canEject { button.isEnabled = canEject }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard places.indices.contains(sender.tag) else { return }
        show(places[sender.tag], inNewTab: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
    }

    func show(_ place: Place, inNewTab: Bool = false) {
        if inNewTab, kernel.commands.isEnabled(.newTab) { kernel.commands.perform(.newTab) }
        kernel.commands.perform(.changeDirectory, .location(place.url))
        validate()
    }
}
