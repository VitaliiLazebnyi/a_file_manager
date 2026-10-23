import AFMContracts
public import AFMKernel
import Foundation

/// Folder tabs (spec 03 › Folder tabs).
///
/// The commands only change the panels' lists of tabs; a panel notices and reads the tab that
/// becomes visible. Tab files are read and written in the background, as jobs. Main thread only,
/// like the panels it works on.
public final class FolderTabsPlugin: Plugin {
    /// A tab that was closed, the folder it showed, and where it was.
    private struct ClosedTab {
        let tab: PanelTabState
        let directory: URL
        let index: Int
    }

    /// Settings key: whether Close All Other Tabs asks first.
    internal static let confirmCloseAllKey = "folderTabs.confirmCloseAll"
    /// Settings key: whether Open Folder in New Tab shows the new tab.
    internal static let foregroundKey = "folderTabs.openDirInForeground"
    /// Settings key: whether new tabs open right of the active tab instead of at the end.
    internal static let nearCurrentKey = "folderTabs.openNearCurrent"
    /// How many closed tabs of a panel can be brought back.
    internal static let closedTabsLimit = 20

    /// The most tabs a panel holds; more are not opened (a tab file with thousands of tabs is
    /// no tab file).
    internal static let tabsPerPanelLimit = 256

    /// The schemes whose tabs connect to a server when they are shown, for a location that no
    /// file system claims (one whose plugin is not loaded; a view, which looks at places that may).
    private static let connectingSchemes: Set<String> = [
        "ftp", "ftps", "sftp", "http", "https", "ssh", "smb", "cifs", "afp", "nfs", "webdav",
        "dav", "davs", "vfolder"
    ]

    /// The most a tab file may hold.
    nonisolated internal static let tabFileLimit = 1 << 20

    /// The plugin's name, for the log.
    public let name = "Folder tabs"

    /// The closed tabs of each panel, the most recent last (spec 03 › Closing tabs,
    /// "Recently closed tabs").
    ///
    /// Kept for the session only.
    private var closedTabs: [ObjectIdentifier: [ClosedTab]] = [:]

    /// Asked whether a location connects to a server (`FileSystemProvider.connectsToServer`).
    private var fileSystems: FileSystemRegistry?

    /// The plugin; it learns of the file systems when it starts.
    public init() {
        // Nothing to set up before `start(in:)`.
    }

    /// Registers the tab commands and adds them to the menus; main thread, once.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        fileSystems = kernel.fileSystems
        registerNewTabs(in: kernel)
        registerFolderOpening(in: kernel)
        registerCopies(in: kernel)
        registerClosing(in: kernel)
        registerSwitching(in: kernel)
        kernel.commands.register(
            Command(
                .exchangeWithTabs,
                "Exchange Directories and Tabs",
                [Shortcut(.character("u"), [.control, .shift])]
            )
        ) { [self] in
            let (left, right) = (kernel.panels.left.tabs, kernel.panels.right.tabs)
            let (leftState, rightState) = (left.state, right.state)
            replace(left, with: rightState)
            replace(right, with: leftState)
        }
        registerNamesAndLocks(in: kernel)
        registerTabFiles(in: kernel)
        Self.addToMenus(kernel)
    }

    /// Duplicate Tab, and Copy and Move Tab to Other Panel.
    private func registerCopies(in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        let tabs = { kernel.panels.source.tabs }
        commands.register(Command(.duplicateTab, "Duplicate Tab")) {
            tabs().insertTab(showing: tabs().active.directory, activate: true)
        }
        commands.register(Command(.copyTabToOtherPanel, "Copy Tab to Other Panel")) { [self] in
            restore([Self.record(of: tabs().active)], in: kernel.panels.target.tabs, activating: 0)
        }
        commands.register(
            Command(.moveTabToOtherPanel, "Move Tab to Other Panel"),
            enabled: { tabs().count > 1 && !tabs().active.isLocked },
            { [self] in
                let moved = Self.record(of: tabs().active)
                // Offered only for an unlocked tab beside others: it can be closed.
                _ = tabs().closeTab(at: tabs().activeIndex)
                restore([moved], in: kernel.panels.target.tabs, activating: 0)
            }
        )
    }

    /// The commands that close tabs and bring closed ones back.
    private func registerClosing(in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        let tabs = { kernel.panels.source.tabs }
        let hasSeveralTabs = { tabs().count > 1 }
        commands.register(
            Command(.closeTab, "Close Tab", [.cmd("w"), Shortcut(.character("w"), .control)]),
            enabled: hasSeveralTabs
        ) { [self] argument in
            close([argument.index ?? tabs().activeIndex], in: tabs())
        }
        commands.register(
            Command(.closeAllTabs, "Close All Other Tabs", [Shortcut(.character("w"), [.control, .shift])]),
            enabled: hasSeveralTabs
        ) { [self] in
            closeOthers(in: tabs(), kernel: kernel)
        }
        commands.register(Command(.closeDuplicateTabs, "Close Duplicate Tabs"), enabled: hasSeveralTabs) { [self] in
            close(Self.duplicates(in: tabs()), in: tabs())
        }
        commands.register(
            Command(.reopenClosedTab, "Reopen Closed Tab"),
            enabled: { [self] in !closedList(of: tabs()).isEmpty },
            { [self] in reopen(closedList(of: tabs()).count - 1, in: tabs()) }
        )
        commands.register(
            Command(.recentlyClosedTabs, "Recently Closed Tabs…"),
            enabled: { [self] in !closedList(of: tabs()).isEmpty },
            { [self] in
                let closed = Array(closedList(of: tabs()).reversed())
                let rows = closed.map { tab in kernel.fileSystems.displayPath(tab.directory) }
                guard let row = kernel.interaction.pickRow("Recently closed tabs", rows: rows, button: "Reopen") else {
                    return
                }
                reopen(closed.count - 1 - row, in: tabs())
            }
        )
    }

    /// Save Tabs, Save Tabs on Both Sides and the two ways of loading a tab file.
    private func registerTabFiles(in owner: Kernel) {
        unowned let kernel = owner
        let commands = kernel.commands
        commands.register(Command(.saveTabs, "Save Tabs to File…")) { [self] argument in
            save(argument, bothSides: false, kernel: kernel)
        }
        commands.register(Command(.saveTabsOfBothSides, "Save Tabs on Both Sides to File…")) { [self] argument in
            save(argument, bothSides: true, kernel: kernel)
        }
        commands.register(Command(.openTabs, "Load Tabs from File, Replace Tabs…")) { [self] argument in
            load(argument, replacing: true, kernel: kernel)
        }
        commands.register(Command(.appendTabs, "Load Tabs from File, Keep Current…")) { [self] argument in
            load(argument, replacing: false, kernel: kernel)
        }
    }

    // MARK: Tabs as records

    /// Whether showing the tab would connect to a server (or look in a place that may): the
    /// file system of the location says so itself; the list of schemes holds for the others.
    internal func connects(_ location: String) -> Bool {
        guard let url = URL(string: location), let scheme = url.scheme?.lowercased() else {
            return false
        }
        if let provider = try? fileSystems?.provider(for: url), provider.connectsToServer {
            return true
        }
        return Self.connectingSchemes.contains(scheme)
    }

    /// Opens tabs for `records` from position `index` on (at the end without one).
    ///
    /// The tab numbered `active` among them becomes the one shown; nil leaves the shown tab as it
    /// is. With `fromFile`, the records come from a file someone else may have written: a tab that
    /// would connect to a server is opened but never made the shown one, so that loading a file
    /// connects nowhere; it connects when the user activates it.
    private func restore(
        _ records: [PanelTabState],
        in tabs: PanelTabs,
        activating active: Int?,
        at index: Int? = nil,
        fromFile: Bool = false,
        room: Int? = nil
    ) {
        var position = min(index ?? tabs.count, tabs.count)
        var opened: [PanelModel] = []
        // Whoever listens is told that the tabs changed once at the end, not for each tab.
        tabs.performBatch {
            // A location that cannot be read is left out.
            let readable = records.compactMap { record in URL(string: record.location).map { (record, $0) } }
            for (record, location) in readable.prefix(max(room ?? Self.tabsPerPanelLimit - tabs.count, 0)) {
                let tab = tabs.insertTab(showing: location, at: position, activate: false)
                let order = ListOrder(key: SortKey(rawValue: record.sortKey) ?? .name, descending: record.descending)
                if tab.sort != order { tab.setSort(order) }
                tab.setShowHidden(record.showHidden)
                (tab.customTitle, tab.isLocked) = (record.title, record.locked)
                opened.append(tab)
                position += 1
            }
            if let active, opened.indices.contains(active),
                !(fromFile && connects(opened[active].directory.absoluteString)),
                let shown = tabs.tabs.firstIndex(where: { $0 === opened[active] })
            {
                tabs.activate(shown)
            }
        }
    }

    /// Gives a panel the tabs of `state` in place of its own; locked tabs go too.
    ///
    /// From a file, the shown tab is one that does not connect to a server; when there is none, the
    /// tab that was shown stays (and with it, nothing connects).
    private func replace(_ tabs: PanelTabs, with state: PanelTabs.State, fromFile: Bool = false) {
        let old = tabs.tabs
        var wanted: Int? = min(max(state.active, 0), max(state.tabs.count - 1, 0))
        if fromFile, let index = wanted, state.tabs.indices.contains(index), connects(state.tabs[index].location) {
            wanted = state.tabs.firstIndex { !connects($0.location) }
        }
        let kept = wanted == nil ? tabs.active : nil
        tabs.performBatch {
            restore(
                state.tabs,
                in: tabs,
                activating: wanted,
                fromFile: fromFile,
                room: Self.tabsPerPanelLimit
            )
            for tab in old where tab !== kept {
                tab.isLocked = false
                if let index = tabs.tabs.firstIndex(where: { $0 === tab }) { tabs.closeTab(at: index) }
            }
        }
    }

    /// Closes every tab but the active one and the locked ones, asking first unless that is
    /// switched off.
    private func closeOthers(in tabs: PanelTabs, kernel: Kernel) {
        let others = tabs.tabs.indices.filter { index in index != tabs.activeIndex && !tabs.tabs[index].isLocked }
        guard !others.isEmpty else {
            return
        }
        if kernel.settings.flag(Self.confirmCloseAllKey, default: true),
            kernel.interaction.choose(
                "Close all tabs?",
                detail: "The current tab and locked tabs stay open.",
                buttons: ["OK", "Cancel"],
                style: .information
            ) != 0
        {
            return
        }
        close(others, in: tabs)
    }

    /// Closes the tabs at `indices` and remembers them for "Reopen Closed Tab".
    private func close(_ indices: [Int], in tabs: PanelTabs) {
        for index in indices.sorted(by: >) where tabs.tabs.indices.contains(index) {
            let closed = ClosedTab(
                tab: Self.record(of: tabs.tabs[index]),
                directory: tabs.tabs[index].directory,
                index: index
            )
            guard tabs.closeTab(at: index) else { continue }
            var list = closedTabs[ObjectIdentifier(tabs), default: []]
            list.append(closed)
            closedTabs[ObjectIdentifier(tabs)] = Array(list.suffix(Self.closedTabsLimit))
        }
    }

    /// The closed tabs of a panel, the most recent last.
    private func closedList(of tabs: PanelTabs) -> [ClosedTab] {
        closedTabs[ObjectIdentifier(tabs)] ?? []
    }

    /// Brings the closed tab numbered `number` (0 is the one closed first) back to where it
    /// was and shows it.
    ///
    /// The commands offer only the numbers there are.
    private func reopen(_ number: Int, in tabs: PanelTabs) {
        var list = closedList(of: tabs)
        let closed = list.remove(at: number)
        closedTabs[ObjectIdentifier(tabs)] = list
        restore([closed.tab], in: tabs, activating: 0, at: closed.index)
    }

    // MARK: Tab files

    /// Saves the source panel's tabs, and with `bothSides` the target panel's, to a tab file.
    private func save(_ argument: CommandArgument, bothSides: Bool, kernel: Kernel) {
        guard let file = TabFileJobs.file(for: argument, question: "Save tabs to file:", kernel: kernel) else {
            return
        }
        let contents = TabFile(
            active: kernel.panels.source.tabs.state,
            inactive: bothSides ? kernel.panels.target.tabs.state : nil
        )
        TabFileJobs.save(contents, to: file, kernel: kernel)
    }

    /// Opens the tabs of a tab file in place of the panels' tabs, or beside them.
    ///
    /// A file with both sides fills both panels: its first section goes to the source.
    private func load(_ argument: CommandArgument, replacing: Bool, kernel: Kernel) {
        guard let file = TabFileJobs.file(for: argument, question: "Load tabs from file:", kernel: kernel) else {
            return
        }
        let (source, target) = (kernel.panels.source, kernel.panels.target)
        TabFileJobs.load(file, kernel: kernel) { [self] contents in
            for (panel, state) in [(source, Optional(contents.active)), (target, contents.inactive)] {
                guard let state else { continue }
                if replacing {
                    replace(panel.tabs, with: state, fromFile: true)
                } else {
                    restore(state.tabs, in: panel.tabs, activating: nil, fromFile: true)
                }
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
