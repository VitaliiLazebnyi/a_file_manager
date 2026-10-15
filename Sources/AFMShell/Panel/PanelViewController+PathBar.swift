import AFMContracts
import AFMKernel
import AppKit

/// The path bar and the menus of the path and of the tabs (spec 03 › Current-directory bar,
/// 05 › Folder tabs).
extension PanelViewController {
    /// The commands a tab's menu offers when a plugin provides them: those of the shared
    /// vocabulary and the ones the folder-tab plugin may add under these names.
    internal static let tabMenuCommands: [CommandID?] = [
        .newTab, "cm_RenameTab", "cm_ToggleLockCurrentTab", nil,
        .closeTab, "cm_CloseOtherTabs", "cm_CloseAllTabs", nil,
        .nextTab, .previousTab
    ]

    /// The mask the path bar shows: the display filter, without what the quick filter adds.
    private var displayMask: String {
        let title = quickFilters[ObjectIdentifier(model)].map { $0.base?.title ?? "" } ?? model.filter?.title ?? ""
        return title.isEmpty ? "*.*" : title
    }

    /// Writes the path with the display mask into the bar, with every folder on the way as a
    /// part that can be clicked. The folders above come from the file system's arithmetic on
    /// the location, which reads nothing.
    internal func updatePathBar() {
        let directory = model.directory
        let path = kernel.fileSystems.displayPath(directory)
        var ancestors: [(location: URL, path: String)] = []
        if let provider = try? kernel.fileSystems.provider(for: directory) {
            var current: URL? = directory
            while let location = current, ancestors.count < 200 {
                ancestors.append((location, provider.displayPath(location)))
                current = provider.parent(of: location)
            }
        }
        // The parts are cut from the path as it is; what is shown has every character that
        // could mislead replaced by one that can be seen, one for one, so the parts stay where they are.
        pathBar.update(
            text: DisplayText.clean((path.hasSuffix("/") ? path : path + "/") + displayMask),
            segments: PathBarView.segments(of: path, ancestors: ancestors.reversed())
        )
        pathBar.toolTip = DisplayText.clean(path)
        updateEjectButton()
    }

    /// The menu of the path bar: copying the path, and the commands about places that are there.
    internal func pathMenu() -> NSMenu {
        focus()
        let menu = MenuBuilder.menu(
            "",
            [.editPath, .directoryHotlist, .directoryHistory, nil, .newTab, .reread],
            commands: commands,
            keys: kernel.keyBindings
        )
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copyPathChosen), keyEquivalent: "")
        copy.target = self
        menu.insertItem(copy, at: 0)
        if menu.items.count > 1 {
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    /// Puts the path of the folder on a pasteboard, as it is written in the bar.
    internal func copyPath(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(kernel.fileSystems.displayPath(model.directory), forType: .string)
    }

    /// The menu of a tab. The commands act on the active tab of the source panel, so the tab
    /// that was clicked is shown first. Nothing while a job runs.
    internal func tabMenu(forTab index: Int) -> NSMenu? {
        guard !commands.isBlocked() else {
            return nil
        }
        focus()
        if index != tabs.activeIndex {
            commands.perform(.activateTab, .index(index))
        }
        return MenuBuilder.menu("", Self.tabMenuCommands, commands: commands, keys: kernel.keyBindings)
    }

    /// Copy Path in the path bar's menu: onto the general pasteboard.
    @objc
    private func copyPathChosen() {
        copyPath(to: .general)
    }
}
