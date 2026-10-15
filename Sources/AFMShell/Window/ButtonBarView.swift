import AFMContracts
import AFMKernel
import AppKit

/// The button bar above the panels (spec 02 › Button bars).
///
/// One button for each command the plugins proposed, or the user's own layout once there is
/// one (`ToolbarRegistry`). The bar knows no command itself. Main thread only.
///
/// The user arranges the bar by dragging: ⌘-drag moves a button (into another group, onto a
/// group's handle for a group of its own, off the bar to remove it), and dragging the handle
/// in front of a group moves the whole group. A group may start a line of its own: while
/// something is dragged an empty line shows below the bar to drop it in. Lines left empty
/// disappear. Every change is stored as the user's layout at once.
internal final class ButtonBarView: NSView, NSDraggingSource {
    /// What an item of the bar stands for in the arrangement.
    internal enum Slot: Equatable {
        /// A button: its line, its group in the line and its place in the group.
        case button(line: Int, group: Int, index: Int)
        /// The handle in front of a group, which is also the separator between two groups.
        case handle(line: Int, group: Int)

        /// The line the item is in.
        internal var line: Int {
            switch self {
            case .button(let line, _, _), .handle(let line, _):
                return line
            }
        }
    }

    /// What is being dragged: a button or a whole group.
    internal enum Dragged: Equatable {
        /// One button.
        case button(line: Int, group: Int, index: Int)
        /// A group with its handle.
        case group(line: Int, group: Int)
    }

    /// Where a drop would put what is dragged.
    internal enum DropTarget: Equatable {
        /// Where a button goes.
        case button(ButtonBarArrangement.Target)
        /// Where a group goes.
        case group(ButtonBarArrangement.Place)
    }

    /// The commands offered by a right click on the bar, when a plugin provides them.
    ///
    /// Spec 05 › Horizontal button bar; the visibility switches are the shell's own.
    internal static let contextCommands: [CommandID?] = [
        .changeButtonBar, .configuration, .resetButtonBar, nil, .showButtonBar, .showDriveButtons, .showCommandLine,
        .showFunctionKeys
    ]
    /// The type of what the bar drags; only the bar's own drags carry it.
    internal static let pasteboardType = NSPasteboard.PasteboardType("com.afilemanager.button-bar-item")
    /// How far from a handle's middle a dropped button still makes a group of its own.
    internal static let handleSnap: CGFloat = 6

    /// The view that lays out the buttons and handles.
    internal let flow = FlowView()
    /// The mark that shows where a drop would go.
    internal let indicator = NSView()
    /// The buttons, in order.
    internal private(set) var buttons: [NSButton] = []
    /// What the bar shows, in order; nil is a separator, `ToolbarRegistry.lineBreak` starts a line.
    internal private(set) var entries: [CommandID?] = []
    /// What each item of `flow` stands for, in the same order.
    internal private(set) var slots: [Slot] = []
    /// What is being dragged, while a drag of the bar's lasts.
    internal var dragged: Dragged?
    /// The kernel whose commands the buttons run.
    private let kernel: Kernel

    /// The bar of the toolbar of `kernel`.
    internal init(kernel: Kernel) {
        self.kernel = kernel
        super.init(frame: .zero)
        addFilling(flow)
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        addSubview(indicator)
        registerForDraggedTypes([Self.pasteboardType])
        rebuild()
    }

    /// Not used: the view is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// The layout without what cannot be shown.
    ///
    /// Buttons whose command no plugin registered are left out, and so are the separators and
    /// line breaks that would then stand at an end, side by side, or around an empty line.
    internal static func entries(
        of layout: [ToolbarRegistry.Button?],
        commands: CommandRegistry
    ) -> [ToolbarRegistry.Button?] {
        let shown = layout.filter { button in
            button.map { $0.command == ToolbarRegistry.lineBreak || commands[$0.command] != nil } ?? true
        }
        var remaining = shown.compactMap(\.self).filter { $0.command != ToolbarRegistry.lineBreak }.makeIterator()
        return ButtonBarArrangement(entries: shown.map { $0?.command }).entries
            .map { id in
                guard let id else {
                    return nil
                }
                return id == ToolbarRegistry.lineBreak
                    ? ToolbarRegistry.Button(command: id, symbol: "") : remaining.next()
            }
    }

    /// The tooltip of a button: the command's title and its main key, `Find Files… (⌥F7)`, and
    /// below them what the button does, when its plugin says (`hint`).
    internal static func toolTip(for command: Command, keys: KeyBindings, hint: String?) -> String {
        let title =
            keys.shortcuts(for: command.id).first.map { "\(command.title) (\($0.displayText))" } ?? command.title
        return hint.map { "\(title)\n\($0)" } ?? title
    }

    /// Draws the bar again from the registry; called when the layout changed.
    internal func rebuild() {
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
            slots.append(.handle(line: line, group: group))
            items.append(makeHandle(for: .group(line: line, group: group), side: side))
        }
        if !layout.isEmpty {
            addHandle()
        }
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
            guard let command = kernel.commands[entry.command] else {
                continue
            }
            let button = makeButton(for: command, symbol: entry.symbol, pictures: pictures, side: side)
            button.onCommandMouseDown = dragHandler(for: .button(line: line, group: group, index: index), of: button)
            slots.append(.button(line: line, group: group, index: index))
            index += 1
            buttons.append(button)
            items.append(button)
        }
        flow.lineBreaks = lineBreaks
        flow.items = items
        validate()
    }

    /// Makes the buttons follow what their commands say: available or not, pressed or not.
    internal func validate() {
        for button in buttons {
            guard let name = button.identifier?.rawValue else {
                continue
            }
            let id = CommandID(rawValue: name)
            let isEnabled = kernel.commands.isEnabled(id)
            let state: NSControl.StateValue = kernel.commands.isChecked(id) ? .on : .off
            if button.isEnabled != isEnabled {
                button.isEnabled = isEnabled
            }
            if button.state != state {
                button.state = state
            }
        }
    }

    /// The commands offered by a right click on the bar; nil when no plugin provides one.
    override internal func menu(for _: NSEvent) -> NSMenu? {
        let menu = MenuBuilder.menu("", Self.contextCommands, commands: kernel.commands, keys: nil)
        return menu.items.isEmpty ? nil : menu
    }

    /// Applies a drop and stores the result as the user's layout (which redraws the bar).
    ///
    /// A button dropped nowhere (`target` nil) is taken off the bar.
    internal func apply(_ dragged: Dragged, to target: DropTarget?) {
        var arrangement = ButtonBarArrangement(entries: entries)
        switch (dragged, target) {
        case (.button(let line, let group, let index), .button(let destination)):
            arrangement.moveButton(line: line, group: group, index: index, to: destination)

        case (.button(let line, let group, let index), nil):
            arrangement.removeButton(line: line, group: group, index: index)

        case (.group(let line, let group), .group(let place)):
            arrangement.moveGroup(line: line, group: group, to: place)

        default:
            return
        }
        guard arrangement.entries != entries else {
            return
        }
        kernel.toolbar.setLayout(arrangement.entries, in: kernel.settings)
    }

    /// A drag of the bar's comes over it: the mark shows where it would go.
    override internal func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    /// A drag of the bar's moves over it: the mark follows.
    override internal func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isOurs(sender), let dragged else {
            return []
        }
        showIndicator(for: dropTarget(for: dragged, at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    /// The drag left the bar: the mark goes.
    override internal func draggingExited(_: (any NSDraggingInfo)?) {
        indicator.isHidden = true
    }

    /// A drag of the bar's was dropped on it: the bar is arranged anew.
    override internal func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        guard isOurs(sender), let item = dragged else {
            return false
        }
        dragged = nil
        guard let target = dropTarget(for: item, at: convert(sender.draggingLocation, from: nil)) else {
            return false
        }
        apply(item, to: target)
        return true
    }

    /// The handle in front of a group, by which the group is dragged.
    private func makeHandle(for group: Dragged, side: CGFloat) -> BarSeparatorView {
        let handle = BarSeparatorView(frame: NSRect(x: 0, y: 0, width: BarSeparatorView.width, height: side))
        handle.onMouseDown = { [weak self, weak handle] event in
            guard let self, let handle else {
                return
            }
            trackDrag(group, of: handle, from: event)
        }
        return handle
    }

    /// The button of `command`: its picture `symbol`, or its name where the system has no such picture.
    private func makeButton(
        for command: Command,
        symbol: String,
        pictures: NSImage.SymbolConfiguration,
        side: CGFloat
    ) -> BarCommandButton {
        let button = BarButton.style(BarCommandButton(title: "", target: self, action: #selector(buttonPressed(_:))))
        button.isBordered = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: command.title) {
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
            for: command,
            keys: kernel.keyBindings,
            hint: kernel.toolbar.hint(for: command.id)
        )
        button.setAccessibilityLabel(command.title)
        return button
    }

    /// What a ⌘-press on `button` does: it starts a drag of `item`, or presses the button when
    /// the mouse does not move.
    private func dragHandler(for item: Dragged, of button: BarCommandButton) -> (NSEvent) -> Void {
        { [weak self, weak button] event in
            guard let self, let button else {
                return
            }
            if !trackDrag(item, of: button, from: event) {
                buttonPressed(button)
            }
        }
    }

    /// A button was pressed: its command runs.
    @objc
    private func buttonPressed(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue {
            kernel.commands.perform(CommandID(rawValue: name))
        }
        // The click itself toggled the button; what it shows is up to the command.
        validate()
    }
}
