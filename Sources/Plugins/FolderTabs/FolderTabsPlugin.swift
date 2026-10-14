import AFMContracts
import AFMKernel
import Foundation

extension CommandID {
    static let newTabInBackground: CommandID = "cm_OpenNewTabBg"
    static let newTabInOtherPanel: CommandID = "cm_OpenNewTabOther"
    static let newTabInBackgroundInOtherPanel: CommandID = "cm_OpenNewTabBgOther"
    static let openInNewTabInOtherPanel: CommandID = "cm_OpenDirInNewTabOther"
    /// Closes every tab but the active one and the locked ones.
    static let closeAllTabs: CommandID = "cm_CloseAllTabs"
    static let closeDuplicateTabs: CommandID = "cm_CloseDuplicateTabs"
    static let toggleTabLock: CommandID = "cm_ToggleLockCurrentTab"
    static let unlockTab: CommandID = "cm_SetTabOptionNormal"
    static let lockTab: CommandID = "cm_SetTabOptionPathLocked"
    static let unlockAllTabs: CommandID = "cm_SetAllTabsOptionNormal"
    static let lockAllTabs: CommandID = "cm_SetAllTabsOptionPathLocked"
    /// `.text`: the new name (empty for the folder's name); without, the user is asked.
    static let renameTab: CommandID = "cm_RenameTab"
    static let moveTabLeft: CommandID = "cm_MoveTabLeft"
    static let moveTabRight: CommandID = "cm_MoveTabRight"
    static let exchangeWithTabs: CommandID = "cm_ExchangeWithTabs"
    static let sourceTabsList: CommandID = "cm_SrcTabsList"
    static let targetTabsList: CommandID = "cm_TrgTabsList"
    static let leftTabsList: CommandID = "cm_LeftTabsList"
    static let rightTabsList: CommandID = "cm_RightTabsList"
    static let duplicateTab: CommandID = "afm_DuplicateTab"
    static let copyTabToOtherPanel: CommandID = "afm_CopyTabToOtherPanel"
    static let moveTabToOtherPanel: CommandID = "afm_MoveTabToOtherPanel"
    static let reopenClosedTab: CommandID = "afm_ReopenClosedTab"
    static let recentlyClosedTabs: CommandID = "afm_RecentlyClosedTabs"
    /// The commands with parameters of the specification (03 › Tab files and storage).
    /// `.location` or `.text`: the tab file; without, the user is asked for it.
    static let saveTabs: CommandID = "SAVETABS"
    static let saveTabsOfBothSides: CommandID = "SAVETABS2"
    static let openTabs: CommandID = "OPENTABS"
    static let appendTabs: CommandID = "APPENDTABS"

    /// `cm_SrcActivateTab1`…`10` and the `Trg`, `Left` and `Right` variants.
    static func activateTab(_ side: String, _ number: Int) -> CommandID { CommandID(rawValue: "cm_\(side)ActivateTab\(number)") }
}

/// Folder tabs (spec 03 › Folder tabs). The commands only change the panels' lists of tabs;
/// a panel notices and reads the tab that becomes visible. Tab files are read and written in
/// the background, as jobs. Main thread only, like the panels it works on.
public final class FolderTabsPlugin: Plugin {
    public let name = "Folder tabs"
    static let confirmCloseAllKey = "folderTabs.confirmCloseAll"
    static let foregroundKey = "folderTabs.openDirInForeground"
    static let nearCurrentKey = "folderTabs.openNearCurrent"
    /// How many closed tabs of a panel can be brought back.
    static let closedTabsLimit = 20

    /// A tab that was closed, and where it was.
    private struct ClosedTab {
        let tab: PanelTabs.State.Tab
        let index: Int
    }

    /// The closed tabs of each panel, the most recent last (spec 03 › Closing tabs,
    /// "Recently closed tabs"). Kept for the session only.
    private var closedTabs: [ObjectIdentifier: [ClosedTab]] = [:]

    public init() {}

    /// Asked whether a location connects to a server (`FileSystemProvider.connectsToServer`).
    private var fileSystems: FileSystemRegistry?

    public func start(in kernel: Kernel) {
        fileSystems = kernel.fileSystems
        let commands = kernel.commands
        let settings = kernel.settings
        let source = { kernel.panels.source }
        let target = { kernel.panels.target }
        let tabs = { kernel.panels.source.tabs }
        let hasSeveralTabs = { tabs().count > 1 }
        let opensNearCurrent = { settings.flag(FolderTabsPlugin.nearCurrentKey, default: false) }
        let control = KeyModifiers.control

        /// Opens a tab at the end, or right of the active tab with "Open new tabs near current
        /// tab". Without a directory the new tab is a copy of the active one.
        func open(in tabs: PanelTabs, showing directory: URL?, activate: Bool) {
            if opensNearCurrent() {
                tabs.insertTab(showing: directory ?? tabs.active.directory, activate: activate)
            } else {
                tabs.openTab(showing: directory, activate: activate)
            }
        }
        /// The folder under the cursor, else the directory shown (spec 03 › Opening tabs).
        func folderUnderCursor() -> URL {
            let model = source().model
            return model.cursorItem.flatMap { $0.isDirectory ? $0.url : nil } ?? model.directory
        }

        // MARK: Opening

        commands.register(Command(.newTab, "New Folder Tab", [.cmd("t"), Shortcut(.character("t"), control)])) {
            open(in: tabs(), showing: nil, activate: true)
        }
        commands.register(Command(.newTabInBackground, "New Folder Tab in Background", [Shortcut(.character("t"), [.control, .shift])])) {
            open(in: tabs(), showing: nil, activate: false)
        }
        commands.register(Command(.newTabInOtherPanel, "New Folder Tab in Other Panel")) {
            open(in: target().tabs, showing: source().model.directory, activate: true)
        }
        commands.register(Command(.newTabInBackgroundInOtherPanel, "New Folder Tab in Other Panel in Background")) {
            open(in: target().tabs, showing: source().model.directory, activate: false)
        }
        // The current tab stays active, so several folders can be opened one after another,
        // unless the user wants the new tab in the foreground.
        commands.register(Command(.openInNewTab, "Open Folder in New Tab", [.cmd("t", .shift), Shortcut(.up, control)]),
                          enabled: { tabs().active.cursorItem?.isDirectory == true }) {
            open(in: tabs(), showing: tabs().active.cursorItem?.url, activate: settings.flag(FolderTabsPlugin.foregroundKey, default: false))
        }
        commands.register(Command(.openInNewTabInOtherPanel, "Open Folder in New Tab of Other Panel", [Shortcut(.up, [.control, .shift])])) {
            open(in: target().tabs, showing: folderUnderCursor(), activate: true)
        }
        commands.register(Command(.duplicateTab, "Duplicate Tab")) {
            tabs().insertTab(showing: tabs().active.directory, activate: true)
        }
        commands.register(Command(.copyTabToOtherPanel, "Copy Tab to Other Panel")) { [self] in
            restore([record(of: tabs().active)], in: target().tabs, activating: 0)
        }
        commands.register(Command(.moveTabToOtherPanel, "Move Tab to Other Panel"), enabled: { hasSeveralTabs() && !tabs().active.isLocked }) { [self] in
            let moved = record(of: tabs().active)
            guard tabs().closeTab(at: tabs().activeIndex) else { return }
            restore([moved], in: target().tabs, activating: 0)
        }

        // MARK: Closing

        commands.register(Command(.closeTab, "Close Tab", [.cmd("w"), Shortcut(.character("w"), control)]), enabled: hasSeveralTabs,
                          parameterized: { [self] argument in
            close([argument.index ?? tabs().activeIndex], in: tabs())
        })
        commands.register(Command(.closeAllTabs, "Close All Other Tabs", [Shortcut(.character("w"), [.control, .shift])]), enabled: hasSeveralTabs) { [self] in
            let others = tabs().tabs.indices.filter { $0 != tabs().activeIndex && !tabs().tabs[$0].isLocked }
            guard !others.isEmpty else { return }
            if settings.flag(FolderTabsPlugin.confirmCloseAllKey, default: true),
               kernel.ui.choose("Close all tabs?", detail: "The current tab and locked tabs stay open.", buttons: ["OK", "Cancel"],
                                style: .information) != 0 { return }
            close(others, in: tabs())
        }
        commands.register(Command(.closeDuplicateTabs, "Close Duplicate Tabs"), enabled: hasSeveralTabs) { [self] in
            close(FolderTabsPlugin.duplicates(in: tabs()), in: tabs())
        }
        commands.register(Command(.reopenClosedTab, "Reopen Closed Tab"), enabled: { [self] in closedTabs[ObjectIdentifier(tabs())]?.isEmpty == false }) { [self] in
            reopen(nil, in: tabs())
        }
        commands.register(Command(.recentlyClosedTabs, "Recently Closed Tabs…"),
                          enabled: { [self] in closedTabs[ObjectIdentifier(tabs())]?.isEmpty == false }) { [self] in
            let closed = Array((closedTabs[ObjectIdentifier(tabs())] ?? []).reversed())
            let rows = closed.map { entry in URL(string: entry.tab.location).map(kernel.fileSystems.displayPath) ?? entry.tab.location }
            guard let row = kernel.ui.pickRow("Recently closed tabs", rows: rows, button: "Reopen") else { return }
            reopen(closed.count - 1 - row, in: tabs())
        }

        // MARK: Switching and arranging

        commands.register(Command(.activateTab, "Activate Tab"), parameterized: { argument in
            if let index = argument.index { tabs().activate(index) }
        })
        commands.register(Command(.nextTab, "Next Tab", [Shortcut(.tab, .control), .cmd("]", .shift)]), enabled: hasSeveralTabs) {
            tabs().activateNeighbour(1)
        }
        commands.register(Command(.previousTab, "Previous Tab", [Shortcut(.tab, [.control, .shift]), .cmd("[", .shift)]),
                          enabled: hasSeveralTabs) {
            tabs().activateNeighbour(-1)
        }
        let sides: [(String, String, () -> PanelHandle)] = [
            ("Src", "Source", source), ("Trg", "Target", target), ("Left", "Left", { kernel.panels.left }), ("Right", "Right", { kernel.panels.right }),
        ]
        for (side, title, panel) in sides {
            for number in 1...10 {
                // The parameter can address any tab (spec 17 › Command parameters): 1 is the first.
                commands.register(Command(CommandID.activateTab(side, number), "\(title): Activate Tab \(number)"), parameterized: { argument in
                    panel().tabs.activate((argument.index ?? number) - 1)
                })
            }
        }
        let lists: [(CommandID, String, [Shortcut], () -> PanelHandle)] = [
            (.sourceTabsList, "List of Open Tabs…", [Shortcut(.character("a"), [.control, .shift])], source),
            (.targetTabsList, "Target: List of Open Tabs…", [], target),
            (.leftTabsList, "Left: List of Open Tabs…", [], { kernel.panels.left }),
            (.rightTabsList, "Right: List of Open Tabs…", [], { kernel.panels.right }),
        ]
        for (id, title, shortcuts, panel) in lists {
            commands.register(Command(id, title, shortcuts)) {
                let tabs = panel().tabs
                let rows = tabs.tabs.indices.map { "\(tabs.title(at: $0))   —   \(kernel.fileSystems.displayPath(tabs.tabs[$0].directory))" }
                if let row = kernel.ui.pickRow("Open tabs", rows: rows, selected: tabs.activeIndex, button: "Activate") { tabs.activate(row) }
            }
        }
        commands.register(Command(.moveTabLeft, "Move Tab Left"), enabled: { tabs().activeIndex > 0 }) {
            tabs().moveTab(from: tabs().activeIndex, to: tabs().activeIndex - 1)
        }
        commands.register(Command(.moveTabRight, "Move Tab Right"), enabled: { tabs().activeIndex < tabs().count - 1 }) {
            tabs().moveTab(from: tabs().activeIndex, to: tabs().activeIndex + 1)
        }
        commands.register(Command(.exchangeWithTabs, "Exchange Directories and Tabs", [Shortcut(.character("u"), [.control, .shift])])) { [self] in
            let (left, right) = (kernel.panels.left.tabs, kernel.panels.right.tabs)
            let (leftState, rightState) = (left.state, right.state)
            replace(left, with: rightState)
            replace(right, with: leftState)
        }

        // MARK: Names and locks

        commands.register(Command(.renameTab, "Rename/Lock Tab…"), parameterized: { argument in
            let tab = tabs().active
            if let name = argument.text {
                tab.customTitle = name.isEmpty ? nil : name
                return
            }
            let current = tab.customTitle ?? tabs().title(at: tabs().activeIndex).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard let answer = kernel.ui.form("Rename tab", fields: [.text("name", "New name:", current),
                                                                    .checkbox("locked", "Lock this tab", tab.isLocked)]) else { return }
            let name = answer.text("name").trimmingCharacters(in: .whitespaces)
            // The folder's own name, or nothing, gives the tab its automatic title back.
            tab.customTitle = name.isEmpty || (tab.customTitle == nil && name == current) ? nil : name
            if tab.isLocked != answer.flag("locked") { tab.isLocked = answer.flag("locked") }
        })
        commands.register(Command(.toggleTabLock, "Lock Tab"), checked: { tabs().active.isLocked }) { tabs().active.isLocked.toggle() }
        commands.register(Command(.lockTab, "Turn On Tab Locking")) { tabs().active.isLocked = true }
        commands.register(Command(.unlockTab, "Turn Off Tab Locking")) { tabs().active.isLocked = false }
        commands.register(Command(.lockAllTabs, "Lock All Tabs")) { tabs().tabs.forEach { $0.isLocked = true } }
        commands.register(Command(.unlockAllTabs, "Unlock All Tabs")) { tabs().tabs.forEach { $0.isLocked = false } }

        // MARK: Tab files

        commands.register(Command(.saveTabs, "Save Tabs to File…"), parameterized: { [self] in save($0, bothSides: false, kernel: kernel) })
        commands.register(Command(.saveTabsOfBothSides, "Save Tabs on Both Sides to File…"),
                          parameterized: { [self] in save($0, bothSides: true, kernel: kernel) })
        commands.register(Command(.openTabs, "Load Tabs from File, Replace Tabs…"), parameterized: { [self] in load($0, replacing: true, kernel: kernel) })
        commands.register(Command(.appendTabs, "Load Tabs from File, Keep Current…"), parameterized: { [self] in load($0, replacing: false, kernel: kernel) })

        kernel.menus.add([.newTab, .openInNewTab, .closeTab, .nextTab, .previousTab], to: .showTabs)
        kernel.menus.add([.closeAllTabs, .closeDuplicateTabs, .reopenClosedTab, .recentlyClosedTabs, .sourceTabsList],
                         to: MenuSection(.show, order: 42))
        kernel.menus.add([.renameTab, .toggleTabLock, .duplicateTab, .copyTabToOtherPanel, .moveTabToOtherPanel, .exchangeWithTabs],
                         to: MenuSection(.show, order: 44))
        kernel.menus.add([.saveTabs, .saveTabsOfBothSides, .openTabs, .appendTabs], to: MenuSection(.show, order: 46))
        kernel.menus.addToContextMenu([.openInNewTab], in: .open, onItemOnly: true)
        kernel.toolbar.add(.newTab, symbol: "plus.rectangle.on.rectangle", group: 60)
        kernel.toolbar.setSymbol("arrow.uturn.backward.square", for: .reopenClosedTab)
        kernel.toolbar.setSymbol("lock", for: .toggleTabLock)
        kernel.preferences.add(PreferencePage(title: "Folder Tabs", preferences: [
            Preference(FolderTabsPlugin.confirmCloseAllKey, "Confirm close all tabs", .flag(default: true)),
            Preference(FolderTabsPlugin.foregroundKey, "Ctrl+Up opens new tab in foreground", .flag(default: false)),
            Preference(FolderTabsPlugin.nearCurrentKey, "Open new tabs near current tab", .flag(default: false)),
        ]))
    }

    // MARK: Tabs as records

    private func record(of tab: PanelModel) -> PanelTabs.State.Tab {
        PanelTabs.State.Tab(location: tab.directory, sortKey: tab.sort.key.rawValue, descending: tab.sort.descending, showHidden: tab.showHidden,
                            title: tab.customTitle, locked: tab.isLocked ? true : nil)
    }

    /// The most tabs a panel holds; more are not opened (a tab file with thousands of tabs is
    /// no tab file).
    static let tabsPerPanelLimit = 256

    /// The schemes whose tabs connect to a server when they are shown, for a location that no
    /// file system claims (one whose plugin is not loaded; a view, which looks at places that may).
    private static let connectingSchemes: Set<String> = ["ftp", "ftps", "sftp", "http", "https", "ssh", "smb", "cifs", "afp", "nfs", "webdav",
                                                         "dav", "davs", "vfolder"]

    /// Whether showing the tab would connect to a server (or look in a place that may): the
    /// file system of the location says so itself; the list of schemes holds for the others.
    func connects(_ location: String) -> Bool {
        guard let url = URL(string: location), let scheme = url.scheme?.lowercased() else { return false }
        if let provider = try? fileSystems?.provider(for: url), provider.connectsToServer { return true }
        return FolderTabsPlugin.connectingSchemes.contains(scheme)
    }

    /// Runs `change` on the tabs, telling whoever listens that the tabs changed once at the
    /// end, not once for each tab opened or closed.
    private func batch(_ tabs: PanelTabs, _ change: () -> Void) {
        tabs.performBatch(change)
    }

    /// Opens tabs for `records` from position `index` on (at the end without one). The tab
    /// numbered `active` among them becomes the one shown; nil leaves the shown tab as it is.
    /// With `fromFile`, the records come from a file someone else may have written: a tab that
    /// would connect to a server is opened but never made the shown one, so that loading a
    /// file connects nowhere; it connects when the user activates it.
    private func restore(_ records: [PanelTabs.State.Tab], in tabs: PanelTabs, at index: Int? = nil, activating active: Int?,
                         fromFile: Bool = false, room: Int? = nil) {
        var position = min(index ?? tabs.count, tabs.count)
        var opened: [PanelModel] = []
        batch(tabs) {
            for record in records.prefix(max(room ?? FolderTabsPlugin.tabsPerPanelLimit - tabs.count, 0)) {
                guard let location = URL(string: record.location) else { continue }
                let tab = tabs.insertTab(showing: location, at: position, activate: false)
                let order = ListOrder(key: SortKey(rawValue: record.sortKey) ?? .name, descending: record.descending)
                if tab.sort != order { tab.setSort(order) }
                tab.setShowHidden(record.showHidden)
                (tab.customTitle, tab.isLocked) = (record.title, record.locked ?? false)
                opened.append(tab)
                position += 1
            }
            if let active, opened.indices.contains(active), !(fromFile && connects(opened[active].directory.absoluteString)),
               let index = tabs.tabs.firstIndex(where: { $0 === opened[active] }) {
                tabs.activate(index)
            }
        }
    }

    /// Gives a panel the tabs of `state` in place of its own; locked tabs go too. From a file,
    /// the shown tab is one that does not connect to a server; when there is none, the tab
    /// that was shown stays (and with it, nothing connects).
    private func replace(_ tabs: PanelTabs, with state: PanelTabs.State, fromFile: Bool = false) {
        let old = tabs.tabs
        var wanted: Int? = min(max(state.active, 0), max(state.tabs.count - 1, 0))
        if fromFile, let index = wanted, state.tabs.indices.contains(index), connects(state.tabs[index].location) {
            wanted = state.tabs.firstIndex { !connects($0.location) }
        }
        let kept = wanted == nil ? tabs.active : nil
        batch(tabs) {
            restore(state.tabs, in: tabs, activating: wanted, fromFile: fromFile, room: FolderTabsPlugin.tabsPerPanelLimit)
            // Nothing was opened when no location could be read; the panel then keeps its tabs.
            guard tabs.count > old.count else { return }
            for tab in old where tab !== kept {
                tab.isLocked = false
                if let index = tabs.tabs.firstIndex(where: { $0 === tab }) { tabs.closeTab(at: index) }
            }
        }
    }

    /// Tabs that show a directory an earlier tab already shows; the active tab is the one
    /// that is kept of its directory, and locked tabs stay (spec 03 › Closing tabs).
    static func duplicates(in tabs: PanelTabs) -> [Int] {
        var seen: Set<String> = [tabs.active.directory.locationKey]
        return tabs.tabs.indices.filter { index in
            guard index != tabs.activeIndex else { return false }
            return !seen.insert(tabs.tabs[index].directory.locationKey).inserted && !tabs.tabs[index].isLocked
        }
    }

    /// Closes the tabs at `indices` and remembers them for "Reopen Closed Tab".
    private func close(_ indices: [Int], in tabs: PanelTabs) {
        for index in indices.sorted(by: >) where tabs.tabs.indices.contains(index) {
            let closed = ClosedTab(tab: record(of: tabs.tabs[index]), index: index)
            guard tabs.closeTab(at: index) else { continue }
            var list = closedTabs[ObjectIdentifier(tabs), default: []]
            list.append(closed)
            closedTabs[ObjectIdentifier(tabs)] = Array(list.suffix(FolderTabsPlugin.closedTabsLimit))
        }
    }

    /// Brings a closed tab back to where it was and shows it; without a number, the one
    /// closed last.
    private func reopen(_ number: Int?, in tabs: PanelTabs) {
        var list = closedTabs[ObjectIdentifier(tabs)] ?? []
        guard let number = number ?? list.indices.last, list.indices.contains(number) else { return }
        let closed = list.remove(at: number)
        closedTabs[ObjectIdentifier(tabs)] = list
        restore([closed.tab], in: tabs, at: closed.index, activating: 0)
    }

    // MARK: Tab files

    /// The file a tab-file command works on: its parameter, or what the user enters. A name
    /// without an extension gets `.tab`.
    private func tabFile(_ argument: CommandArgument, question: String, kernel: Kernel) -> URL? {
        let directory = kernel.panels.source.model.directory
        if let location = argument.location { return location }
        guard let text = argument.text ?? kernel.ui.prompt(question, value: kernel.fileSystems.displayPath(directory.appending(name: "tabs.tab"))),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let file = kernel.fileSystems.location(from: text, relativeTo: directory)
        return file.pathExtension.isEmpty ? file.appendingPathExtension("tab") : file
    }

    /// The most a tab file may hold.
    static let tabFileLimit = 1 << 20

    private enum TabFileError: LocalizedError {
        case notAFile(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .notAFile(let path): return "\(path) is not a file."
            case .tooLarge(let path): return "\(path) is too large to be a tab file."
            }
        }
    }

    private enum SaveOutcome {
        case saved, declined
        case failed(Error)
    }

    private func save(_ argument: CommandArgument, bothSides: Bool, kernel: Kernel) {
        guard let file = tabFile(argument, question: "Save tabs to file:", kernel: kernel) else { return }
        let contents = TabFile(active: kernel.panels.source.tabs.state, inactive: bothSides ? kernel.panels.target.tabs.state : nil)
        let data = Data(contents.text(displayPath: kernel.fileSystems.displayPath).utf8)
        let (fileSystems, ui) = (kernel.fileSystems, kernel.ui)
        kernel.jobs.run(title: "Save tabs", work: { monitor -> SaveOutcome in
            do {
                let provider = try fileSystems.provider(for: file)
                let existing = provider.item(at: file)
                if let existing {
                    // Only a file is replaced; a folder or anything else of that name stays.
                    guard !existing.isDirectory, !existing.isSpecial else { throw TabFileError.notAFile(fileSystems.displayPath(file)) }
                    let overwrite = monitor.ask {
                        ui.choose("Overwrite the tab file?", detail: fileSystems.displayPath(file), buttons: ["Overwrite", "Cancel"], style: .warning) == 0
                    }
                    guard overwrite else { return .declined }
                }
                // Written under another name and renamed when complete: the old file is
                // there until the new one is, and a failure leaves it as it was.
                let temporary = file.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
                do {
                    let writer = try provider.write(temporary)
                    try writer.write(data)
                    try writer.close(attributes: FileAttributes())
                    try provider.move(temporary, to: file, replacing: existing != nil)
                } catch {
                    try? provider.remove(temporary)
                    throw error
                }
                return .saved
            } catch {
                return .failed(error)
            }
        }, completion: { outcome in
            switch outcome {
            case .saved: kernel.panels.refresh([file.deletingLastPathComponent()], focus: file)
            case .failed(let error): kernel.ui.report(error, title: "The tabs could not be saved.")
            case .declined: break
            }
        })
    }

    private func load(_ argument: CommandArgument, replacing: Bool, kernel: Kernel) {
        guard let file = tabFile(argument, question: "Load tabs from file:", kernel: kernel) else { return }
        let fileSystems = kernel.fileSystems
        let (source, target) = (kernel.panels.source, kernel.panels.target)
        let base = source.model.directory
        kernel.jobs.run(title: "Load tabs", work: { _ in
            Result { () throws -> TabFile? in
                let provider = try fileSystems.provider(for: file)
                if let item = provider.item(at: file), item.isDirectory || item.isSpecial { throw TabFileError.notAFile(fileSystems.displayPath(file)) }
                let reader = try provider.read(file)
                defer { reader.close() }
                var data = Data()
                while let block = try reader.read(upToCount: 1 << 16), !block.isEmpty {
                    data.append(block)
                    // A tab file is a few lines of text; anything long is something else.
                    guard data.count <= FolderTabsPlugin.tabFileLimit else { throw TabFileError.tooLarge(fileSystems.displayPath(file)) }
                }
                // Worked out here, not on the main thread: the file may be a megabyte of lines.
                return TabFile(text: TabFile.text(decoding: data), location: { fileSystems.location(from: $0, relativeTo: base) })
            }
        }, completion: { [self] result in
            switch result {
            case .failure(let error):
                kernel.ui.report(error, title: "The tabs could not be loaded.")
            case .success(let parsed):
                guard let contents = parsed else {
                    kernel.ui.inform("The file holds no tabs.", detail: fileSystems.displayPath(file), style: .warning)
                    return
                }
                // A file with both sides fills both panels: its first section goes to the source.
                for (panel, state) in [(source, Optional(contents.active)), (target, contents.inactive)] {
                    guard let state else { continue }
                    if replacing { replace(panel.tabs, with: state, fromFile: true) } else { restore(state.tabs, in: panel.tabs, activating: nil, fromFile: true) }
                }
            }
        })
    }
}
