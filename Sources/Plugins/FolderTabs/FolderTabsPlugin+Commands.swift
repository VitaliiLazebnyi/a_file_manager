import AFMContracts
import AFMKernel
import Foundation

/// The commands that switch between tabs, arrange them and name or lock them, and the plugin's
/// menus and preferences (main thread).
///
/// The kernel keeps what is registered here; it must not be kept by it in turn, so every handler
/// holds it unowned.
extension FolderTabsPlugin {
    /// A panel as the tab commands name it, with its List of Open Tabs command.
    private struct TabSide {
        /// The panel of that side, asked when the command runs.
        let panel: () -> any PanelHandle
        /// The side in the names of the activate commands: `Src`, `Trg`, `Left`, `Right`.
        let prefix: String
        /// The side in the titles of the activate commands.
        let title: String
        /// The side's List of Open Tabs command, its title and its keys.
        let list: Command
    }

    /// Puts the commands into the menus, the context menu and the toolbar, and the Folder Tabs
    /// page into the preferences.
    internal static func addToMenus(_ kernel: Kernel) {
        kernel.menus.add([.newTab, .openInNewTab, .closeTab, .nextTab, .previousTab], to: .showTabs)
        kernel.menus.add(
            [.closeAllTabs, .closeDuplicateTabs, .reopenClosedTab, .recentlyClosedTabs, .sourceTabsList],
            to: MenuSection(.show, order: 42)
        )
        kernel.menus.add(
            [.renameTab, .toggleTabLock, .duplicateTab, .copyTabToOtherPanel, .moveTabToOtherPanel, .exchangeWithTabs],
            to: MenuSection(.show, order: 44)
        )
        kernel.menus.add(
            [.saveTabs, .saveTabsOfBothSides, .openTabs, .appendTabs],
            to: MenuSection(.show, order: 46)
        )
        kernel.menus.addToContextMenu([.openInNewTab], in: .open, onItemOnly: true)
        kernel.toolbar.add(
            .newTab,
            symbol: "plus.rectangle.on.rectangle",
            group: 60,
            hint: "Open the current folder in a new tab."
        )
        kernel.toolbar.setSymbol("arrow.uturn.backward.square", for: .reopenClosedTab)
        kernel.toolbar.setSymbol("lock", for: .toggleTabLock)
        kernel.preferences.add(
            PreferencePage(
                title: "Folder Tabs",
                preferences: [
                    Preference(Self.confirmCloseAllKey, "Confirm close all tabs", .flag(default: true)),
                    Preference(Self.foregroundKey, "Ctrl+Up opens new tab in foreground", .flag(default: false)),
                    Preference(Self.nearCurrentKey, "Open new tabs near current tab", .flag(default: false))
                ]
            )
        )
    }

    /// The panels as the tab commands name them, in the order their commands are registered.
    private static func sides(of owner: Kernel) -> [TabSide] {
        unowned let kernel = owner
        return [
            TabSide(
                panel: { kernel.panels.source },
                prefix: "Src",
                title: "Source",
                list: Command(.sourceTabsList, "List of Open Tabs…", [Shortcut(.character("a"), [.control, .shift])])
            ),
            TabSide(
                panel: { kernel.panels.target },
                prefix: "Trg",
                title: "Target",
                list: Command(.targetTabsList, "Target: List of Open Tabs…")
            ),
            TabSide(
                panel: { kernel.panels.left },
                prefix: "Left",
                title: "Left",
                list: Command(.leftTabsList, "Left: List of Open Tabs…")
            ),
            TabSide(
                panel: { kernel.panels.right },
                prefix: "Right",
                title: "Right",
                list: Command(.rightTabsList, "Right: List of Open Tabs…")
            )
        ]
    }

    /// What a tab file or the list of closed tabs keeps of a tab.
    internal static func record(of tab: PanelModel) -> PanelTabState {
        PanelTabState(
            location: tab.directory,
            order: tab.sort,
            showHidden: tab.showHidden,
            title: tab.customTitle,
            locked: tab.isLocked
        )
    }

    /// Tabs that show a directory an earlier tab already shows; the active tab is the one
    /// that is kept of its directory, and locked tabs stay (spec 03 › Closing tabs).
    internal static func duplicates(in tabs: PanelTabs) -> [Int] {
        var seen: Set<String> = [tabs.active.directory.locationKey]
        return tabs.tabs.indices.filter { index in
            guard index != tabs.activeIndex else {
                return false
            }
            return !seen.insert(tabs.tabs[index].directory.locationKey).inserted && !tabs.tabs[index].isLocked
        }
    }

    /// Opens a tab at the end, or right of the active tab with "Open new tabs near current
    /// tab"; without a directory the new tab is a copy of the active one.
    private static func open(in tabs: PanelTabs, showing directory: URL?, activate: Bool, settings: any SettingsStore) {
        if settings.flag(nearCurrentKey, default: false) {
            tabs.insertTab(showing: directory ?? tabs.active.directory, activate: activate)
        } else {
            tabs.openTab(showing: directory, activate: activate)
        }
    }

    /// Asks which of the panel's tabs to show, the active one picked, and shows it.
    private static func pickTab(in tabs: PanelTabs, kernel: Kernel) {
        let rows = tabs.tabs.indices.map { index in
            "\(tabs.title(at: index))   —   \(kernel.fileSystems.displayPath(tabs.tabs[index].directory))"
        }
        let picked = kernel.interaction.pickRow("Open tabs", rows: rows, selected: tabs.activeIndex, button: "Activate")
        if let picked {
            tabs.activate(picked)
        }
    }

    /// Gives the active tab the name `newName` (empty for the folder's name); without one, asks
    /// for the name and whether the tab is locked.
    private static func rename(_ tabs: PanelTabs, to newName: String?, kernel: Kernel) {
        let tab = tabs.active
        if let newName {
            tab.customTitle = newName.isEmpty ? nil : newName
            return
        }
        let current =
            tab.customTitle
            ?? tabs.title(at: tabs.activeIndex).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        guard
            let answer = kernel.interaction.form(
                "Rename tab",
                fields: [
                    .text("name", "New name:", current),
                    .checkbox("locked", "Lock this tab", tab.isLocked)
                ]
            )
        else { return }
        let typed = answer.text("name").trimmingCharacters(in: .whitespaces)
        // The folder's own name, or nothing, gives the tab its automatic title back.
        tab.customTitle = typed.isEmpty || (tab.customTitle == nil && typed == current) ? nil : typed
        if tab.isLocked != answer.flag("locked") { tab.isLocked = answer.flag("locked") }
    }

    /// New Folder Tab, in the background and in the other panel.
    internal func registerNewTabs(in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        let settings = kernel.settings
        let (source, target) = ({ kernel.panels.source }, { kernel.panels.target })
        let tabs = { kernel.panels.source.tabs }
        commands.register(
            Command(.newTab, "New Folder Tab", [.cmd("t"), Shortcut(.character("t"), .control)])
        ) {
            Self.open(in: tabs(), showing: nil, activate: true, settings: settings)
        }
        commands.register(
            Command(
                .newTabInBackground,
                "New Folder Tab in Background",
                [Shortcut(.character("t"), [.control, .shift])]
            )
        ) {
            Self.open(in: tabs(), showing: nil, activate: false, settings: settings)
        }
        commands.register(Command(.newTabInOtherPanel, "New Folder Tab in Other Panel")) {
            Self.open(in: target().tabs, showing: source().model.directory, activate: true, settings: settings)
        }
        commands.register(Command(.newTabInBackgroundInOtherPanel, "New Folder Tab in Other Panel in Background")) {
            Self.open(in: target().tabs, showing: source().model.directory, activate: false, settings: settings)
        }
    }

    /// Open Folder in New Tab, here and in the other panel.
    internal func registerFolderOpening(in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        let settings = kernel.settings
        let tabs = { kernel.panels.source.tabs }
        // The current tab stays active, so several folders can be opened one after another,
        // unless the user wants the new tab in the foreground.
        commands.register(
            Command(.openInNewTab, "Open Folder in New Tab", [.cmd("t", .shift), Shortcut(.upArrow, .control)]),
            enabled: { tabs().active.cursorItem?.isDirectory == true },
            {
                let activate = settings.flag(Self.foregroundKey, default: false)
                Self.open(in: tabs(), showing: tabs().active.cursorItem?.url, activate: activate, settings: settings)
            }
        )
        commands.register(
            Command(
                .openInNewTabInOtherPanel,
                "Open Folder in New Tab of Other Panel",
                [Shortcut(.upArrow, [.control, .shift])]
            )
        ) {
            // The folder under the cursor, else the directory shown (spec 03 › Opening tabs).
            let model = kernel.panels.source.model
            let folder = model.cursorItem.flatMap { item in item.isDirectory ? item.url : nil } ?? model.directory
            Self.open(in: kernel.panels.target.tabs, showing: folder, activate: true, settings: settings)
        }
    }

    /// Activate Tab, Next and Previous Tab, the numbered tabs of each side, the lists of open tabs,
    /// and Move Tab Left and Right.
    internal func registerSwitching(in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        let tabs = { kernel.panels.source.tabs }
        let hasSeveralTabs = { tabs().count > 1 }
        commands.register(Command(.activateTab, "Activate Tab")) { argument in
            if let index = argument.index { tabs().activate(index) }
        }
        commands.register(
            Command(.nextTab, "Next Tab", [Shortcut(.tab, .control), .cmd("]", .shift)]),
            enabled: hasSeveralTabs
        ) {
            tabs().activateNeighbour(1)
        }
        commands.register(
            Command(.previousTab, "Previous Tab", [Shortcut(.tab, [.control, .shift]), .cmd("[", .shift)]),
            enabled: hasSeveralTabs
        ) {
            tabs().activateNeighbour(-1)
        }
        let sides = Self.sides(of: kernel)
        for side in sides {
            for number in 1...10 {
                // The parameter can address any tab (spec 17 › Command parameters): 1 is the first.
                commands.register(
                    Command(CommandID.activateTab(side.prefix, number), "\(side.title): Activate Tab \(number)")
                ) { argument in
                    side.panel().tabs.activate((argument.index ?? number) - 1)
                }
            }
        }
        for side in sides {
            commands.register(side.list) { Self.pickTab(in: side.panel().tabs, kernel: kernel) }
        }
        commands.register(
            Command(.moveTabLeft, "Move Tab Left"),
            enabled: { tabs().activeIndex > 0 },
            { tabs().moveTab(from: tabs().activeIndex, to: tabs().activeIndex - 1) }
        )
        commands.register(
            Command(.moveTabRight, "Move Tab Right"),
            enabled: { tabs().activeIndex < tabs().count - 1 },
            { tabs().moveTab(from: tabs().activeIndex, to: tabs().activeIndex + 1) }
        )
    }

    /// Rename/Lock Tab and the lock commands.
    internal func registerNamesAndLocks(in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        let tabs = { kernel.panels.source.tabs }
        commands.register(Command(.renameTab, "Rename/Lock Tab…")) { argument in
            Self.rename(tabs(), to: argument.text, kernel: kernel)
        }
        commands.register(
            Command(.toggleTabLock, "Lock Tab"),
            checked: { tabs().active.isLocked },
            { tabs().active.isLocked.toggle() }
        )
        commands.register(Command(.lockTab, "Turn On Tab Locking")) { tabs().active.isLocked = true }
        commands.register(Command(.unlockTab, "Turn Off Tab Locking")) { tabs().active.isLocked = false }
        commands.register(Command(.lockAllTabs, "Lock All Tabs")) {
            for tab in tabs().tabs { tab.isLocked = true }
        }
        commands.register(Command(.unlockAllTabs, "Unlock All Tabs")) {
            for tab in tabs().tabs { tab.isLocked = false }
        }
    }
}
