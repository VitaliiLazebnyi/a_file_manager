import AFMContracts
public import AFMKernel
public import Foundation

extension CommandID {
    /// The directory tree of the source panel's volume in a window (spec 12 › Directory Tree dialog).
    public static let directoryTree: CommandID = "cm_CDtree"
    /// The history list with the folders that were only passed through (spec 03 › Directory history list).
    public static let directoryHistoryUnthinned: CommandID = "cm_DirectoryHistoryNoThinning"
    /// "Save now" of the history page (spec 13 › Operation › History).
    public static let saveDirectoryHistory: CommandID = "cm_ConfigSaveDirHistory"
    /// "Delete now" of the history page.
    public static let clearDirectoryHistory: CommandID = "afm_ClearDirectoryHistory"
    /// Adds the source panel's directory to the hotlist, or removes it when it is listed.
    public static let toggleHotlistEntry: CommandID = "afm_HotlistToggleCurrentDir"
    /// The hotlist editor on its own (spec 12 › Directory hotlist editor).
    public static let configureHotlist: CommandID = "afm_ConfigureHotlist"
}

/// Directory hotlist, history list and directory tree (spec 03 › Directory hotlist, 03 ›
/// Directory history list, 12 › Directory Tree dialog, 12 › Directory hotlist editor).
///
/// The hotlist and the history are shown as pick lists through `kernel.ui`, so they need no
/// window of their own; the tree and the hotlist editor are windows. Everything here runs on
/// the main thread and works on locations only; the one thing that reads file systems, the
/// tree, does so on background threads (`TreeScanner`, `TreeCache`).
public final class PlacesPlugin: Plugin {
    public let name = "Places"

    enum Keys {
        static let hotlist = "hotlist"
        static let favorites = "places.hotlist.favorites"
        static let thinning = "places.history.thinning"
        static let saveHistory = "places.history.save"
        static let historyShown = "places.history.shown"
        static let showFrequent = "places.history.showFrequent"
        static let frequentShown = "places.history.frequentShown"
    }

    /// Set when the plugin starts; safe to use from any thread.
    private(set) var treeCache = TreeCache(directory: nil)
    private let treeCacheDirectory: URL?
    private let keepsTreesOnDisk: Bool
    private let favorites: [HotlistEntry]
    private let now: () -> Date
    /// Weak: the kernel owns the plugin.
    private weak var owner: Kernel?
    private var tracker: DirectoryHistoryTracker?
    private var subscription: AnyObject?
    private var treeWindow: DirectoryTreeWindowController?
    /// Stored data that could not be read in full is reported once per key and run.
    private var reportedKeys = Set<String>()
    private var lastNoted: URL?
    /// Shows the hotlist editor and returns the changed list, or nil on Cancel. Tests put a
    /// script here; without one the editor window is used.
    var editHotlist: ((Hotlist) -> Hotlist?)?

    /// Directory trees are cached in `treeCacheDirectory`; without one they go to the program's
    /// folder in Application Support, or stay in memory only when `keepsTreesOnDisk` is off.
    /// `favorites` are the standard places offered next to the user's hotlist; `now` is the
    /// clock the history measures stays with. Tests replace all of these.
    public init(
        treeCacheDirectory: URL? = nil, keepsTreesOnDisk: Bool = true,
        favorites: [HotlistEntry] = MacFavorites.entries(),
        now: @escaping () -> Date = Date.init
    ) {
        self.treeCacheDirectory = treeCacheDirectory
        self.keepsTreesOnDisk = keepsTreesOnDisk
        self.favorites = favorites
        self.now = now
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        self.owner = owner
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let ownFolder = applicationSupport?.appendingPathComponent(kernel.productName, isDirectory: true)
            .appendingPathComponent("TreeCache", isDirectory: true)
        treeCache = TreeCache(directory: treeCacheDirectory ?? (keepsTreesOnDisk ? ownFolder : nil))
        let commands = kernel.commands
        let settings = kernel.settings
        let tracker = DirectoryHistoryTracker(settings: settings.scoped(to: "places"), now: now) { [weak self] in
            self?.storedDataProblem($0, in: kernel)
        }
        tracker.savesChanges = { settings.flag(Keys.saveHistory, default: true) }
        self.tracker = tracker
        // The panels announce every change of directory; the history is kept from that.
        subscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            if case .locationChanged = event { self?.noteLocation(of: panel, in: kernel) }
        }

        commands.register(Command(.directoryHotlist, "Directory Hotlist…", [Shortcut(.character("d"), .control)])) {
            [self] in
            showHotlist(in: kernel)
        }
        commands.register(Command(.toggleHotlistEntry, "Add or Remove Current Directory in Hotlist")) { [self] in
            toggleCurrentDirectory(at: [], in: kernel)
        }
        commands.register(Command(.configureHotlist, "Configure Directory Hotlist…")) { [self] in
            configureHotlist(in: kernel)
        }
        commands.register(Command(.directoryHistory, "Directory History…", [Shortcut(.down, .option)])) { [self] in
            showHistory(in: kernel, thinning: settings.flag(Keys.thinning, default: true))
        }
        commands.register(
            Command(
                .directoryHistoryUnthinned, "Directory History (All Folders)…", [Shortcut(.down, [.option, .shift])])
        ) { [self] in
            showHistory(in: kernel, thinning: false, limited: false)
        }
        commands.register(Command(.saveDirectoryHistory, "Save Directory History Now", runsDuringJobs: true)) {
            tracker.save()
        }
        commands.register(Command(.clearDirectoryHistory, "Delete Directory History", runsDuringJobs: true)) {
            tracker.clear()
        }
        commands.register(Command(.directoryTree, "Directory Tree…", [.f(10, .option)])) { [self] in
            let source = kernel.panels.source.model
            let controller = treeWindow ?? DirectoryTreeWindowController(kernel: kernel, cache: treeCache)
            treeWindow = controller
            controller.show(for: source.directory, showHidden: source.showHidden)
        }

        kernel.menus.add([.directoryTree, .directoryHotlist, .directoryHistory], to: .commandsPlaces)
        kernel.toolbar.add(
            .directoryHotlist, symbol: "star", group: 30,
            hint: "Your favourite folders: jump to one, or add the current folder.")
        kernel.toolbar.add(
            .directoryHistory, symbol: "clock.arrow.circlepath", group: 30,
            hint: "The folders you visited recently: jump back to one.")
        kernel.toolbar.add(
            .directoryTree, symbol: "folder.badge.gearshape", group: 30,
            hint: "Show all folders as a tree and jump to one.")
        kernel.toolbar.setSymbol("star.leadinghalf.filled", for: .toggleHotlistEntry)
        kernel.toolbar.setSymbol("star.square", for: .configureHotlist)

        kernel.preferences.add(
            PreferencePage(
                title: "Hotlist and History",
                preferences: [
                    Preference(
                        Keys.favorites, "Offer the Mac's standard folders (Favorites) in the directory hotlist",
                        .flag(default: true)),
                    Preference(
                        Keys.thinning, "Directory history thinning: leave out folders that were only passed through",
                        .flag(default: true)),
                    Preference(Keys.saveHistory, "Save the directory history between sessions", .flag(default: true)),
                    Preference(Keys.historyShown, "Maximum history items to show:", .text(default: "26")),
                    Preference(
                        Keys.showFrequent, "Show frequently used folders in the history list", .flag(default: true)),
                    Preference(Keys.frequentShown, "Maximum frequently used folders to show:", .text(default: "30"))
                ]))
    }

    /// Writes the tree cache before the program quits, away from the main thread (a tree of
    /// millions of folders is a file of many megabytes). `stop` then finds nothing left to write.
    public func prepareToQuit(cancellation _: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        let cache = treeCache
        BlockingCalls.run {
            cache.flush()
            completion()
        }
    }

    public func stop() {
        if let kernel = owner, kernel.settings.flag(Keys.saveHistory, default: true) { tracker?.save() }
        // A scan that went on in the background ends here; what the cache holds is written now.
        treeWindow?.shutDown()
        treeCache.flush()
    }

    /// Writes the history changes that are waiting for their delay to end.
    func flushHistory() { tracker?.flush() }

    /// Tells the user, once, that stored data was damaged. The data itself is kept aside.
    private func storedDataProblem(_ message: String, in kernel: Kernel) {
        guard reportedKeys.insert(message).inserted else { return }
        performOnMainLoop {
            kernel.ui.inform(
                "Some saved data could not be read",
                detail: message + " The original is kept in the settings under the same name with “.unreadable”.",
                style: .warning)
        }
    }

    // MARK: Following the panels

    private func side(of panel: any PanelHandle, in kernel: Kernel) -> DirectoryHistoryTracker.Side {
        panel === kernel.panels.right ? .right : .left
    }

    private func noteLocation(of panel: any PanelHandle, in kernel: Kernel) {
        let directory = panel.model.directory
        tracker?.visited(directory, on: side(of: panel, in: kernel))
        // A folder a panel shows exists: a cached tree that lacks it learns of it. The disks are
        // asked on a thread of their own, and a folder that was just noted is not asked again.
        guard lastNoted?.isSameLocation(as: directory) != true,
            let provider = try? kernel.fileSystems.provider(for: directory)
        else { return }
        lastNoted = directory
        treeCache.noteFolder {
            let root = TreeRoots.root(
                for: directory, places: provider.places(), providerRoot: provider.root(of: directory))
            return DirectoryTree.relativePath(of: directory, below: root).map { ($0, root) }
        }
    }

    // MARK: Hotlist

    /// The user's hotlist, from the settings.
    public func hotlist(in kernel: Kernel) -> Hotlist {
        StoredSettings.load(Hotlist.self, key: Keys.hotlist, in: kernel.settings.scoped(to: "places")) { [self] in
            storedDataProblem($0, in: kernel)
        } ?? Hotlist()
    }

    private func store(_ hotlist: Hotlist, in kernel: Kernel) {
        kernel.settings.scoped(to: "places").set(hotlist, forKey: Keys.hotlist)
    }

    /// Whether choosing the entry would lead to `directory`.
    private func leads(_ entry: HotlistEntry, to directory: URL, in kernel: Kernel) -> Bool {
        guard case .changeDirectory(let path, false) = HotlistAction(entry.command), !path.isEmpty else { return false }
        return kernel.fileSystems.location(from: path, relativeTo: directory).isSameLocation(as: directory)
    }

    private enum HotlistLevel {
        case user(Hotlist.Path)
        case favorites
    }

    /// Ctrl+D: the hotlist as a pick list, one level at a time. A submenu opens as the next
    /// list and Cancel leads back out of it; the second button opens the entry in a new tab
    /// (Shift+Enter of the specification).
    private func showHotlist(in kernel: Kernel) {
        var level = HotlistLevel.user([])
        while true {
            let list = hotlist(in: kernel)
            let current = kernel.panels.source.model.directory
            let isCurrent = { [self] entry in leads(entry, to: current, in: kernel) }
            let menu: HotlistMenu
            var title = "Directory Hotlist"
            switch level {
            case .user(let path):
                menu = HotlistMenu(
                    list, at: path,
                    offersFavorites: !favorites.isEmpty && kernel.settings.flag(Keys.favorites, default: true),
                    isCurrent: isCurrent)
                if let submenu = list.entry(at: path) { title += " › " + submenu.displayTitle }

            case .favorites:
                menu = HotlistMenu(places: favorites, isCurrent: isCurrent)
                title += " › Favorites"
            }
            guard
                let answer = kernel.ui.form(
                    title, detail: "", fields: [.list("row", "", menu.titles, selected: menu.selected)],
                    buttons: ["Go", "Open in New Tab"]), menu.rows.indices.contains(answer.index("row"))
            else {
                // Leaving a submenu shows the level above again.
                switch level {
                case .user(let path) where !path.isEmpty: level = .user(Array(path.dropLast()))
                case .favorites: level = .user([])
                case .user: return
                }
                continue
            }
            switch menu.rows[answer.index("row")].action {
            case .run(let entry):
                run(entry, inNewTab: answer.button == 1, in: kernel)
                return

            case .open(let path):
                level = .user(path)

            case .openFavorites:
                level = .favorites

            case .separator:
                continue

            case .addCurrent, .removeCurrent:
                guard case .user(let path) = level else { return }
                toggleCurrentDirectory(at: path, in: kernel)
                return

            case .configure:
                configureHotlist(in: kernel)
                return
            }
        }
    }

    /// "Add/remove current dir": the source panel's directory joins one level of the hotlist,
    /// or leaves it when it is listed there.
    private func toggleCurrentDirectory(at parent: Hotlist.Path, in kernel: Kernel) {
        var list = hotlist(in: kernel)
        let current = kernel.panels.source.model.directory
        // The entries the menu shows are the ones that count: a hidden entry is left alone.
        if let index = list.index(
            in: parent, where: { $0.kind == .item && !list.isHidden($0) && leads($0, to: current, in: kernel) })
        {
            list.remove(at: parent + [index])
        } else {
            let path = kernel.fileSystems.displayPath(current)
            let title = current.lastPathComponent.isEmpty || current.path == "/" ? path : current.lastPathComponent
            guard list.add(.item(title, command: HotlistAction.changeDirectoryCommand(to: path)), to: parent) != nil
            else {
                kernel.ui.inform(
                    "The directory hotlist is full.", detail: "It holds at most \(Hotlist.limit) entries.",
                    style: .warning)
                return
            }
        }
        store(list, in: kernel)
    }

    private func configureHotlist(in kernel: Kernel) {
        let current = kernel.panels.source.model.directory
        let edit = editHotlist ?? { HotlistEditorWindowController.run($0, kernel: kernel, currentDirectory: current) }
        if let changed = edit(hotlist(in: kernel)) { store(changed, in: kernel) }
    }

    /// Does what a hotlist entry says (spec 03 › Directory hotlist, "Choosing an entry"): its
    /// command in the source panel, and its target path in the other panel.
    private func run(_ entry: HotlistEntry, inNewTab: Bool, in kernel: Kernel) {
        let (source, target) = (kernel.panels.source, kernel.panels.target)
        // Read before anything moves: a command may change which panel is the source.
        let targetLocation = HotlistAction.targetPath(entry.target).map {
            kernel.fileSystems.location(from: $0, relativeTo: target.model.directory)
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
        if let targetLocation { target.show(targetLocation) }
    }

    // MARK: History

    private func limit(_ key: String, default value: Int, in kernel: Kernel) -> Int {
        min(
            max(
                Int(kernel.settings.text(key, default: String(value)).trimmingCharacters(in: .whitespaces)) ?? value, 1
            ), 200)
    }

    /// Alt+Down: the directories the source panel visited, the last one first, and below them
    /// the folders used most often. The list comes back after "Remove", so several entries
    /// can be cleared in a row.
    ///
    /// The "maximum to show" settings apply to Alt+Down, with or without thinning; the
    /// unthinned list of Alt+Shift+Down shows everything (`limited: false`).
    private func showHistory(in kernel: Kernel, thinning: Bool, limited: Bool = true) {
        guard let tracker else { return }
        let panel = kernel.panels.source
        let side = side(of: panel, in: kernel)
        var selected: Int?
        while true {
            let current = panel.model.directory
            // Also right after the start, before any event came, the list has the current folder.
            tracker.visited(current, on: side)
            let showsFrequent = kernel.settings.flag(Keys.showFrequent, default: true)
            let menu = HistoryMenu(
                history: tracker.history(of: side).shown(
                    thinning: thinning, limit: limited ? limit(Keys.historyShown, default: 26, in: kernel) : nil),
                frequent: showsFrequent
                    ? tracker.frequent.top(limited ? limit(Keys.frequentShown, default: 30, in: kernel) : nil) : [],
                current: current, displayPath: kernel.fileSystems.displayPath)
            let fields = [
                FormField.list(
                    "row", "", menu.titles, selected: min(selected ?? menu.selected, max(menu.rows.count - 1, 0)))
            ]
            guard
                let answer = kernel.ui.form(
                    "Directory History", detail: "", fields: fields,
                    buttons: ["Go", "Open in New Tab", "Open in Other Panel", "Remove from List"]),
                menu.rows.indices.contains(answer.index("row"))
            else { return }
            let row = menu.rows[answer.index("row")]
            guard let directory = row.directory else { continue }
            switch answer.button {
            case 1:
                _ = panel.tabs.openTab(showing: directory)
                return

            case 2:
                kernel.panels.target.show(directory)
                return

            case 3:
                if case .frequent = row {
                    tracker.removeFrequent(directory)
                } else {
                    tracker.remove(directory, from: side)
                }
                selected = answer.index("row")

            default:
                panel.show(directory)
                return
            }
        }
    }
}

/// Hands a block to the main thread through the run loop (all modes that count), not through the
/// main dispatch queue: a block that asks the user something runs a modal dialog, and a dialog
/// started from inside a block of the main queue keeps every later block of the queue waiting.
func performOnMainLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    // The main run loop runs its blocks on the main thread.
    RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
