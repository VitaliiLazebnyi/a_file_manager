import AFMContracts
import AFMKernel
import AppKit

/// The drive button bar (spec 02 › Drive button bar).
///
/// One button for every place and volume the file systems offer. A click shows the place in
/// the source panel, Shift+click in a new folder tab. A drive that can be ejected has an eject
/// button next to it. Hidden until the user switches it on, as in Total Commander. Main thread
/// only.
internal final class DriveBarView: NSView {
    /// The buttons of the places, in order.
    internal private(set) var buttons: [NSButton] = []
    /// The eject buttons, by the index of their place.
    internal private(set) var ejectButtons: [Int: NSButton] = [:]
    /// The places the buttons show.
    internal private(set) var places: [Place] = []
    /// The kernel whose commands the buttons run.
    private let kernel: Kernel
    /// Where the places come from.
    private let store: PlacesStore
    /// The view that lays out the buttons.
    private let flow = FlowView()

    /// The bar of `kernel` with the places of `store`.
    internal init(kernel: Kernel, places store: PlacesStore) {
        self.kernel = kernel
        self.store = store
        super.init(frame: .zero)
        addFilling(flow)
        // Volumes come and go, and the file systems answer in their own time: the bar follows the store.
        store.observe { [weak self] in self?.rebuild() }
        rebuild()
    }

    /// Not used: the view is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// The place `directory` is in: the one with the longest path that contains it; nil for none.
    internal static func currentPlace(among places: [Place], for directory: URL) -> Int? {
        let path = directory.standardized.path
        let candidates = places.enumerated()
            .filter { _, place in
                guard place.url.scheme == directory.scheme, place.url.host == directory.host else {
                    return false
                }
                let root = place.url.standardized.path
                return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        return candidates.max { $0.element.url.path.count < $1.element.url.path.count }?.offset
    }

    /// The picture of a kind of place.
    private static func symbol(for kind: Place.Kind) -> String {
        switch kind {
        case .home:
            return "house"

        case .folder:
            return "folder"

        case .internalDisk:
            return "internaldrive"

        case .externalDisk:
            return "externaldrive"
        }
    }

    /// Shows the places the file systems have answered with.
    ///
    /// They come from `PlacesStore`, which asks them in the background: nothing here waits for
    /// a file system.
    internal func rebuild() {
        places = store.all
        ejectButtons = [:]
        buttons = places.enumerated().map { index, place in makeButton(for: place, at: index) }
        var items: [NSView] = []
        for (index, button) in buttons.enumerated() {
            items.append(button)
            guard places[index].canBeEjected else {
                continue
            }
            let eject = makeEjectButton(for: places[index], at: index)
            ejectButtons[index] = eject
            items.append(eject)
        }
        flow.items = items
        validate()
    }

    /// Presses the button of the place the source panel shows, and greys the bar out while the
    /// panel cannot go anywhere (a job is running).
    internal func validate() {
        let isEnabled = kernel.commands.isEnabled(.changeDirectory)
        let current = Self.currentPlace(among: places, for: kernel.panels.source.model.directory)
        for (index, button) in buttons.enumerated() {
            let state: NSControl.StateValue = index == current ? .on : .off
            if button.isEnabled != isEnabled {
                button.isEnabled = isEnabled
            }
            if button.state != state {
                button.state = state
            }
        }
        let canEject = kernel.commands.isEnabled(.ejectVolume)
        for button in ejectButtons.values where button.isEnabled != canEject {
            button.isEnabled = canEject
        }
    }

    /// Shows `place` in the source panel, or with `inNewTab` in a new folder tab of it.
    internal func show(_ place: Place, inNewTab: Bool) {
        if inNewTab, kernel.commands.isEnabled(.newTab) {
            kernel.commands.perform(.newTab)
        }
        kernel.commands.perform(.changeDirectory, .location(place.url))
        validate()
    }

    /// The button of `place`, the `index`th.
    private func makeButton(for place: Place, at index: Int) -> NSButton {
        let button = BarButton.make(target: self, action: #selector(buttonPressed(_:)))
        button.title = DisplayText.clean(place.name)
        button.image = NSImage(systemSymbolName: Self.symbol(for: place.kind), accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.tag = index
        button.toolTip = DisplayText.clean(kernel.fileSystems.displayPath(place.url))
        button.sizeToFit()
        button.frame.size.height = BarButton.height
        return button
    }

    /// The eject button of `place`, the `index`th.
    private func makeEjectButton(for place: Place, at index: Int) -> NSButton {
        let eject = BarButton.style(BarCommandButton(title: "", target: self, action: #selector(ejectPressed(_:))))
        eject.isBordered = false
        eject.setButtonType(.momentaryPushIn)
        eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        eject.imagePosition = .imageOnly
        eject.tag = index
        let title = "Eject “\(DisplayText.clean(place.name))”"
        eject.toolTip = title
        eject.setAccessibilityLabel(title)
        eject.frame.size = NSSize(width: 18, height: BarButton.height)
        return eject
    }

    /// An eject button was pressed: the drive of its place is ejected.
    @objc
    private func ejectPressed(_ sender: NSButton) {
        guard places.indices.contains(sender.tag) else {
            return
        }
        kernel.commands.perform(.ejectVolume, .location(places[sender.tag].url))
    }

    /// A place's button was pressed: the source panel goes there, with Shift in a new tab.
    @objc
    private func buttonPressed(_ sender: NSButton) {
        guard places.indices.contains(sender.tag) else {
            return
        }
        show(places[sender.tag], inNewTab: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
    }

    deinit {
        // Nothing to release.
    }
}
