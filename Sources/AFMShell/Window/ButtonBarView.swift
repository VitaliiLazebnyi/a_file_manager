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
        let button = NSButton(title: "", target: target, action: action)
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

/// The button bar above the panels (spec 02 › Button bars): one button for each command the
/// plugins proposed, or the user's own layout once there is one (`ToolbarRegistry`). The bar
/// knows no command itself. Main thread only.
final class ButtonBarView: NSView {
    private let kernel: Kernel
    private let flow = FlowView()
    private(set) var buttons: [NSButton] = []
    /// What the bar shows, in order; nil is a separator.
    private(set) var entries: [CommandID?] = []

    /// The commands offered by a right click on the bar, when a plugin provides them
    /// (spec 05 › Horizontal button bar); the visibility switches are the shell's own.
    static let contextCommands: [CommandID?] = [
        .changeButtonBar, .configuration, nil, .showButtonBar, .showDriveButtons, .showCommandLine, .showFunctionKeys,
    ]

    init(kernel: Kernel) {
        self.kernel = kernel
        super.init(frame: .zero)
        flow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)
        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: topAnchor), flow.bottomAnchor.constraint(equalTo: bottomAnchor),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor), flow.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The layout without what cannot be shown: buttons whose command no plugin registered are
    /// left out, and so are the separators that would then stand at an end or side by side.
    static func entries(of layout: [ToolbarRegistry.Button?], commands: CommandRegistry) -> [ToolbarRegistry.Button?] {
        var entries: [ToolbarRegistry.Button?] = []
        for button in layout {
            if let button {
                if commands[button.command] != nil { entries.append(button) }
            } else if let last = entries.last, last != nil {
                entries.append(nil)
            }
        }
        if let last = entries.last, last == nil { entries.removeLast() }
        return entries
    }

    /// The command's title and its main key: `Find Files… (⌥F7)`.
    static func toolTip(for command: Command, keys: KeyBindings) -> String {
        guard let shortcut = keys.shortcuts(for: command.id).first else { return command.title }
        return "\(command.title) (\(shortcut.displayText))"
    }

    /// Draws the bar again from the registry; called when the layout changed.
    func rebuild() {
        let layout = ButtonBarView.entries(of: kernel.toolbar.layout(from: kernel.settings), commands: kernel.commands)
        entries = layout.map { $0?.command }
        buttons = []
        let iconSize = BarButton.iconSize(from: kernel.settings)
        let side = max(BarButton.height, iconSize + 14)
        let pictures = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        flow.items = layout.map { entry in
            guard let entry, let command = kernel.commands[entry.command] else {
                let separator = BarButton.separator()
                separator.frame.size.height = side
                return separator
            }
            let button = BarButton.make(target: self, action: #selector(buttonPressed(_:)))
            if let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: command.title) {
                button.image = image.withSymbolConfiguration(pictures) ?? image
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
                button.frame.size = NSSize(width: side + 6, height: side)
            } else {
                // A symbol this system does not have: the button carries the command's name.
                button.title = command.title
                button.sizeToFit()
                button.frame.size.height = side
            }
            button.identifier = NSUserInterfaceItemIdentifier(command.id.rawValue)
            button.toolTip = ButtonBarView.toolTip(for: command, keys: kernel.keyBindings)
            button.setAccessibilityLabel(command.title)
            buttons.append(button)
            return button
        }
        validate()
    }

    /// Makes the buttons follow what their commands say: available or not, pressed or not.
    func validate() {
        for button in buttons {
            guard let name = button.identifier?.rawValue else { continue }
            let id = CommandID(rawValue: name)
            let isEnabled = kernel.commands.isEnabled(id), state: NSControl.StateValue = kernel.commands.isChecked(id) ? .on : .off
            if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
            if button.state != state { button.state = state }
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { kernel.commands.perform(CommandID(rawValue: name)) }
        // The click itself toggled the button; what it shows is up to the command.
        validate()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = MenuBuilder.menu("", ButtonBarView.contextCommands, commands: kernel.commands, keys: nil)
        return menu.items.isEmpty ? nil : menu
    }
}

/// The drive button bar (spec 02 › Drive button bar): one button for every place and volume
/// the file systems offer. A click shows the place in the source panel, Shift+click in a new
/// folder tab. Hidden until the user switches it on, as in Total Commander. Main thread only.
final class DriveBarView: NSView {
    private let kernel: Kernel
    private let store: PlacesStore
    private let flow = FlowView()
    private(set) var buttons: [NSButton] = []
    private(set) var places: [Place] = []

    init(kernel: Kernel, places store: PlacesStore) {
        self.kernel = kernel
        self.store = store
        super.init(frame: .zero)
        flow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)
        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: topAnchor), flow.bottomAnchor.constraint(equalTo: bottomAnchor),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor), flow.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Volumes come and go, and the file systems answer in their own time: the bar follows the store.
        store.observe { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        buttons = places.enumerated().map { index, place in
            let button = BarButton.make(target: self, action: #selector(buttonPressed(_:)))
            button.title = DisplayText.clean(place.name)
            button.image = NSImage(systemSymbolName: DriveBarView.symbol(for: place.kind), accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.tag = index
            button.toolTip = DisplayText.clean(kernel.fileSystems.displayPath(place.url))
            button.sizeToFit()
            button.frame.size.height = BarButton.height
            return button
        }
        flow.items = buttons
        validate()
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
        let current = DriveBarView.currentPlace(among: places, for: kernel.panels.source.model.directory)
        for (index, button) in buttons.enumerated() {
            let state: NSControl.StateValue = index == current ? .on : .off
            if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
            if button.state != state { button.state = state }
        }
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
