import AFMContracts
import AFMKernel
import AppKit

/// The volume of a panel: its figures (free space), the volume list of the drive button, and
/// the eject button of the path bar.
extension PanelViewController {
    /// A question about the volume of a tab's folder that is out.
    private struct VolumeQuestion {
        /// The tab that asked.
        let id: ObjectIdentifier
        /// Its folder when it asked.
        let directory: URL
        /// Set when the answer is no longer wanted.
        let flag: CancellationFlag
        /// The file system that is asked.
        let provider: any FileSystemProvider
    }

    /// Whether places of this kind are disks, which the volume list shows apart from the others.
    private static func isDisk(_ kind: Place.Kind) -> Bool {
        kind == .internalDisk || kind == .externalDisk
    }

    /// The symbol of a place of this kind in the volume list.
    private static func symbol(of kind: Place.Kind) -> String {
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

    /// Opens the volume list, as a click on the drive button does.
    internal func showVolumeList() {
        focus()
        volumeButton.performClick(nil)
    }

    /// The list is filled from the places every file system offers. They are asked for in the
    /// background (a file system may have to look at its volumes first); the menu shows the
    /// ones that are known, and takes the others in when they arrive while it is open. The
    /// header menu is filled here as well.
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            fillHeaderMenu()
            return
        }
        guard menu === volumeButton.menu else {
            return
        }
        fillVolumeMenu(menu)
    }

    /// The volume list opens.
    internal func menuWillOpen(_ menu: NSMenu) {
        if menu === volumeButton.menu {
            volumeMenuIsOpen = true
        }
    }

    /// The volume list closes.
    internal func menuDidClose(_ menu: NSMenu) {
        if menu === volumeButton.menu {
            volumeMenuIsOpen = false
        }
    }

    /// More places are known than when the volume list was last filled.
    internal func placesDidChange() {
        if volumeMenuIsOpen, let menu = volumeButton.menu {
            fillVolumeMenu(menu)
        }
        updateEjectButton()
    }

    /// Shows the eject button of the path bar while the folder is on a drive that can be ejected.
    internal func updateEjectButton() {
        pathBar.ejectableVolumeName = host?.ejectableVolume(containing: model.directory)?.name
    }

    /// A file system reports new figures for a volume: every tab that shows a place at or below its
    /// root asks for them again, in the background, and takes the answer unless it moved on.
    @objc
    internal func volumeInfoChanged(_ note: Notification) {
        guard let provider = note.object as? (any FileSystemProvider) else {
            return
        }
        let root = note.userInfo?[FileSystemRegistry.volumeRootKey] as? URL
        for tab in tabs.tabs {
            let directory = tab.directory
            guard let own = try? kernel.fileSystems.provider(for: directory),
                (own as AnyObject) === (provider as AnyObject),
                root.map({ directory.isSameLocation(as: $0) || directory.isInside($0) }) ?? true
            else {
                continue
            }
            askVolume(of: tab, from: provider)
        }
    }

    /// The own icons of some files have arrived (`IconStore.didArrive`).
    @objc
    internal func iconsArrived(_ note: Notification) {
        if let paths = note.userInfo?[IconStore.pathsKey] as? Set<String> {
            iconsArrived(for: paths)
        }
    }

    /// Asks the file system about the volume of a tab's folder, on one of the kernel's threads
    /// for calls that block (`BlockingCalls`): the same question about the same folder is out
    /// once, whoever asks (a reading of the folder asks it too), and it is given up when the
    /// tab is closed or the window goes. While a question is out, no second one is sent for
    /// the tab: it is asked about again when the answer has come, so the last figures always
    /// win and a file system that does not answer holds one thread, not one per report.
    private func askVolume(of tab: PanelModel, from provider: any FileSystemProvider) {
        let id = ObjectIdentifier(tab)
        guard volumeAsking[id] == nil else {
            volumeAskAgain.insert(id)
            return
        }
        let question = VolumeQuestion(id: id, directory: tab.directory, flag: CancellationFlag(), provider: provider)
        volumeAsking[id] = question.flag
        BlockingCalls.answer(
            from: provider as AnyObject,
            to: "volume " + question.directory.locationKey,
            cancellation: question.flag,
            { provider.volume(of: question.directory, cancellation: $0) },
            then: { [weak self, weak tab] (answer: VolumeInfo??) in self?.answered(question, with: answer ?? nil, for: tab) }
        )
    }

    /// The answer to `question`, for `tab` (nil once it is gone).
    private func answered(_ question: VolumeQuestion, with volume: VolumeInfo?, for tab: PanelModel?) {
        let id = question.id
        guard volumeAsking[id] === question.flag else {
            return
        }
        volumeAsking[id] = nil
        let again = volumeAskAgain.remove(id) != nil
        // A tab that is gone; its address may belong to another one by now.
        guard let tab, !question.flag.isCancelled, tabs.tabs.contains(where: { $0 === tab }) else {
            return
        }
        if again {
            askVolume(of: tab, from: question.provider)
        } else if let volume, tab.directory.isSameLocation(as: question.directory) {
            tab.setVolume(volume)
        }
    }

    /// Fills the volume list with the places known so far: the disks, then the other places.
    private func fillVolumeMenu(_ menu: NSMenu) {
        let title = menu.items.first?.title ?? ""
        menu.removeAllItems()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        var lastKind: Place.Kind?
        for place in host?.placesForVolumeList(of: self) ?? [] {
            if let lastKind, Self.isDisk(place.kind) != Self.isDisk(lastKind) {
                menu.addItem(.separator())
            }
            lastKind = place.kind
            let item = menu.addItem(
                withTitle: DisplayText.clean(place.name),
                action: #selector(placeChosen(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = place.url
            item.image = NSImage(systemSymbolName: Self.symbol(of: place.kind), accessibilityDescription: nil)
        }
    }

    /// A place of the volume list was chosen: the panel goes there.
    @objc
    private func placeChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            performFocused(.changeDirectory, .location(url))
        }
    }
}
