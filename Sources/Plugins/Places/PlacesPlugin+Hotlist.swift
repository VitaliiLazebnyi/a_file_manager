import AFMContracts
public import AFMKernel
import Foundation

/// The directory hotlist: the Ctrl+D pick list, adding and removing the current directory, the editor.
extension PlacesPlugin {
    /// The level of the hotlist a pick list shows.
    private enum HotlistLevel {
        /// The top level (an empty path) or a submenu of the user's list.
        case user(Hotlist.Path)
        /// The Mac's standard folders.
        case favorites
    }

    /// One level of the hotlist as the pick list shows it.
    private struct HotlistPage {
        /// The rows.
        let menu: HotlistMenu
        /// The level "Add current dir" adds to: the Favorites offer no such item.
        let parent: Hotlist.Path
        /// The title of the list.
        let title: String
    }

    /// The user's hotlist, from the settings.
    public func hotlist(in kernel: Kernel) -> Hotlist {
        let settings = kernel.settings.scoped(to: "places")
        return StoredSettings.load(Hotlist.self, key: Keys.hotlist, in: settings) { [self] message in
            storedDataProblem(message, in: kernel)
        } ?? Hotlist()
    }

    /// Ctrl+D: the top level of the hotlist as a pick list.
    internal func showHotlist(in kernel: Kernel) {
        showHotlist(in: kernel, level: .user([]))
    }

    /// "Add/remove current dir": the source panel's directory joins one level of the hotlist,
    /// or leaves it when it is listed there.
    internal func toggleCurrentDirectory(at parent: Hotlist.Path, in kernel: Kernel) {
        var list = hotlist(in: kernel)
        let current = kernel.panels.source.model.directory
        // The entries the menu shows are the ones that count: a hidden entry is left alone.
        if let index = list.index(
            in: parent,
            where: { $0.kind == .item && !list.isHidden($0) && leads($0, to: current, in: kernel) }
        ) {
            list.remove(at: parent + [index])
        } else {
            let path = kernel.fileSystems.displayPath(current)
            let title = current.lastPathComponent.isEmpty || current.path == "/" ? path : current.lastPathComponent
            guard list.add(.item(title, command: HotlistAction.changeDirectoryCommand(to: path)), to: parent) != nil
            else {
                kernel.interaction.inform(
                    "The directory hotlist is full.",
                    detail: "It holds at most \(Hotlist.limit) entries.",
                    style: .warning
                )
                return
            }
        }
        store(list, in: kernel)
    }

    /// The hotlist editor (or the script of a test); a changed list is stored, Cancel keeps the old one.
    internal func configureHotlist(in kernel: Kernel) {
        let current = kernel.panels.source.model.directory
        let edit =
            editHotlist ?? { list in HotlistEditorWindowController.run(list, kernel: kernel, currentDirectory: current)
            }
        if let changed = edit(hotlist(in: kernel)) {
            store(changed, in: kernel)
        }
    }

    /// Writes `hotlist` to the settings.
    private func store(_ hotlist: Hotlist, in kernel: Kernel) {
        kernel.settings.scoped(to: "places").set(hotlist, forKey: Keys.hotlist)
    }

    /// Whether choosing the entry would lead to `directory`.
    private func leads(_ entry: HotlistEntry, to directory: URL, in kernel: Kernel) -> Bool {
        guard case .changeDirectory(let path, false) = HotlistAction(entry.command), !path.isEmpty else {
            return false
        }
        return kernel.fileSystems.location(from: path, relativeTo: directory).isSameLocation(as: directory)
    }

    /// Ctrl+D: the hotlist as a pick list, one level at a time.
    ///
    /// A submenu opens as the next list and Cancel leads back out of it; the second button opens
    /// the entry in a new tab (Shift+Enter of the specification).
    private func showHotlist(in kernel: Kernel, level: HotlistLevel) {
        let page = hotlistPage(level, in: kernel)
        let menu = page.menu
        guard
            let answer = kernel.interaction.form(
                page.title,
                detail: "",
                fields: [.list("row", "", menu.titles, selected: menu.selected)],
                buttons: ["Go", "Open in New Tab"]
            ), menu.rows.indices.contains(answer.index("row"))
        else {
            leave(level, in: kernel)
            return
        }
        switch menu.rows[answer.index("row")].action {
        case .run(let entry):
            run(entry, inNewTab: answer.button == 1, in: kernel)

        case .open(let path):
            showHotlist(in: kernel, level: .user(path))

        case .openFavorites:
            showHotlist(in: kernel, level: .favorites)

        case .separator:
            showHotlist(in: kernel, level: level)

        case .addCurrent, .removeCurrent:
            toggleCurrentDirectory(at: page.parent, in: kernel)

        case .configure:
            configureHotlist(in: kernel)
        }
    }

    /// What the pick list of `level` shows, with the source panel's directory marked.
    private func hotlistPage(_ level: HotlistLevel, in kernel: Kernel) -> HotlistPage {
        let list = hotlist(in: kernel)
        let current = kernel.panels.source.model.directory
        let isCurrent = { [self] entry in leads(entry, to: current, in: kernel) }
        switch level {
        case .user(let path):
            let menu = HotlistMenu(
                list,
                at: path,
                offersFavorites: !favorites.isEmpty && kernel.settings.flag(Keys.favorites, default: true),
                isCurrent: isCurrent
            )
            let title = list.entry(at: path).map { "Directory Hotlist › " + $0.displayTitle } ?? "Directory Hotlist"
            return HotlistPage(menu: menu, parent: path, title: title)

        case .favorites:
            let menu = HotlistMenu(places: favorites, isCurrent: isCurrent)
            return HotlistPage(menu: menu, parent: [], title: "Directory Hotlist › Favorites")
        }
    }

    /// Cancel in the pick list of `level`: leaving a submenu shows the level above again.
    private func leave(_ level: HotlistLevel, in kernel: Kernel) {
        switch level {
        case .user(let path) where !path.isEmpty:
            showHotlist(in: kernel, level: .user(Array(path.dropLast())))

        case .favorites:
            showHotlist(in: kernel)

        case .user:
            break
        }
    }

    /// Does what a hotlist entry says (spec 03 › Directory hotlist, "Choosing an entry"): its
    /// command in the source panel, and its target path in the other panel.
    private func run(_ entry: HotlistEntry, inNewTab: Bool, in kernel: Kernel) {
        let (source, target) = (kernel.panels.source, kernel.panels.target)
        // Read before anything moves: a command may change which panel is the source.
        let targetLocation = HotlistAction.targetPath(entry.target)
            .map { path in
                kernel.fileSystems.location(from: path, relativeTo: target.model.directory)
            }
        switch HotlistAction(entry.command) {
        case .changeDirectory(let path, let focusingOnIt):
            let location = kernel.fileSystems.location(from: path, relativeTo: source.model.directory)
            let parent = focusingOnIt ? (try? kernel.fileSystems.provider(for: location))?.parent(of: location) : nil
            if inNewTab {
                source.tabs.openTab(showing: parent ?? location)
            } else if let parent {
                source.show(parent, focus: location.lastPathComponent)
            } else {
                source.show(location)
            }

        case .command(let id, let argument):
            kernel.commands.perform(id, argument)

        case .nothing:
            break
        }
        if let targetLocation {
            target.show(targetLocation)
        }
    }
}
