import AFMContracts
public import AFMKernel
import AppKit
public import Foundation

/// Directory hotlist, history list and directory tree (spec 03 › Directory hotlist, 03 ›
/// Directory history list, 12 › Directory Tree dialog, 12 › Directory hotlist editor).
///
/// The hotlist and the history are shown as pick lists through `kernel.interaction`, so they need no
/// window of their own; the tree and the hotlist editor are windows. Everything here runs on
/// the main thread and works on locations only; the one thing that reads file systems, the
/// tree, does so on background threads (`TreeScanner`, `TreeCache`).
public final class PlacesPlugin: Plugin {
    /// The settings keys of the plugin.
    internal enum Keys {
        /// The user's hotlist, in the plugin's corner of the settings.
        internal static let hotlist = "hotlist"
        /// Whether the hotlist offers the Mac's standard folders.
        internal static let favorites = "places.hotlist.favorites"
        /// Whether Alt+Down leaves out the folders that were only passed through.
        internal static let thinning = "places.history.thinning"
        /// Whether the history is kept between sessions.
        internal static let saveHistory = "places.history.save"
        /// How many history entries Alt+Down shows.
        internal static let historyShown = "places.history.shown"
        /// Whether the history list shows the frequently used folders.
        internal static let showFrequent = "places.history.showFrequent"
        /// How many frequently used folders the history list shows.
        internal static let frequentShown = "places.history.frequentShown"
    }

    /// The plugin's name.
    public let name = "Places"

    /// Set when the plugin starts; safe to use from any thread.
    internal private(set) var treeCache = TreeCache(directory: nil)
    /// Where the tree cache goes; nil for the program's folder in Application Support.
    private let treeCacheDirectory: URL?
    /// Whether the trees are written to files at all.
    private let keepsTreesOnDisk: Bool
    /// The standard places offered next to the user's hotlist.
    internal let favorites: [HotlistEntry]
    /// The clock the history measures stays with.
    private let now: () -> Date
    /// Weak: the kernel owns the plugin.
    private weak var owner: Kernel?
    /// The histories of the panels, once the plugin started.
    private var tracker: DirectoryHistoryTracker?
    /// The subscription to the panels' events.
    private var subscription: AnyObject?
    /// The Directory Tree window, once it was opened; it is kept for the next time.
    internal private(set) var treeWindow: DirectoryTreeWindowController?
    /// Puts the tree window on screen.
    ///
    /// Tests replace it, so that no window shows in the session they run in, and look at what it
    /// was asked to show.
    internal var present: @MainActor (NSWindowController) -> Void = { $0.showWindow(nil) }
    /// Stored data that could not be read in full is reported once per key and run.
    private var reportedKeys = Set<String>()
    /// The folder last handed to the tree cache, so it is not asked for again.
    private var lastNoted: URL?
    /// Shows the hotlist editor and returns the changed list, or nil on Cancel.
    ///
    /// Tests put a script here; without one the editor window is used.
    internal var editHotlist: ((Hotlist) -> Hotlist?)?

    /// Directory trees are cached in `treeCacheDirectory`; without one they go to the program's
    /// folder in Application Support, or stay in memory only when `keepsTreesOnDisk` is off.
    ///
    /// `favorites` are the standard places offered next to the user's hotlist; `now` is the clock
    /// the history measures stays with. Tests replace all of these. With `opensWindows` off, the
    /// Directory Tree window is made but never put on screen (for tests of the whole program).
    public init(
        treeCacheDirectory: URL? = nil,
        keepsTreesOnDisk: Bool = true,
        favorites: [HotlistEntry] = MacFavorites.entries(),
        now: @escaping () -> Date = Date.init,
        opensWindows: Bool = true
    ) {
        self.treeCacheDirectory = treeCacheDirectory
        self.keepsTreesOnDisk = keepsTreesOnDisk
        self.favorites = favorites
        self.now = now
        if !opensWindows {
            present = { _ in
                // Made but never put on screen.
            }
        }
    }

    /// Reads the histories and registers the commands, menus, toolbar buttons and preferences.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        self.owner = owner
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let ownFolder = applicationSupport?.appendingPathComponent(kernel.productName, isDirectory: true)
            .appendingPathComponent("TreeCache", isDirectory: true)
        treeCache = TreeCache(directory: treeCacheDirectory ?? (keepsTreesOnDisk ? ownFolder : nil))
        let settings = kernel.settings
        let historyTracker = DirectoryHistoryTracker(
            settings: settings.scoped(to: "places"),
            now: now
        ) { [weak self] message in
            self?.storedDataProblem(message, in: kernel)
        }
        historyTracker.savesChanges = { settings.flag(Keys.saveHistory, default: true) }
        tracker = historyTracker
        // The panels announce every change of directory; the history is kept from that.
        subscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            if case .locationChanged = event {
                self?.noteLocation(of: panel, in: kernel)
            }
        }
        registerHotlistCommands(in: kernel)
        registerHistoryCommands(in: kernel, tracker: historyTracker)
        kernel.commands.register(Command(.directoryTree, "Directory Tree…", [.f(10, .option)])) { [self] in
            let source = kernel.panels.source.model
            let controller =
                treeWindow
                ?? DirectoryTreeWindowController(
                    kernel: kernel,
                    cache: treeCache,
                    hiddenScanLimit: DirectoryTreeWindowController.standardHiddenScanLimit
                ) { NSSound.beep() }
            treeWindow = controller
            controller.present = present
            controller.show(for: source.directory, showHidden: source.showHidden)
        }
        addButtons(in: kernel)
        addPreferences(in: kernel)
    }

    /// Writes the tree cache before the program quits, away from the main thread (a tree of
    /// millions of folders is a file of many megabytes). `stop` then finds nothing left to write.
    @preconcurrency
    public func prepareToQuit(cancellation _: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        let cache = treeCache
        BlockingCalls.run {
            cache.flush()
            completion()
        }
    }

    /// Saves the history (unless that is off), ends a scan of the tree window and writes the tree cache.
    public func stop() {
        if let kernel = owner, kernel.settings.flag(Keys.saveHistory, default: true) {
            tracker?.save()
        }
        // A scan that went on in the background ends here; what the cache holds is written now.
        treeWindow?.shutDown()
        treeCache.flush()
    }

    /// Writes the history changes that are waiting for their delay to end.
    internal func flushHistory() { tracker?.flush() }

    /// Tells the user, once, that stored data was damaged.
    ///
    /// The data itself is kept aside.
    internal func storedDataProblem(_ message: String, in kernel: Kernel) {
        guard reportedKeys.insert(message).inserted else {
            return
        }
        performOnMainLoop {
            kernel.interaction.inform(
                "Some saved data could not be read",
                detail: message + " The original is kept in the settings under the same name with “.unreadable”.",
                style: .warning
            )
        }
    }

    /// Ctrl+D, the hotlist toggle and the hotlist editor.
    private func registerHotlistCommands(in kernel: Kernel) {
        let commands = kernel.commands
        commands.register(
            Command(.directoryHotlist, "Directory Hotlist…", [Shortcut(.character("d"), .control)])
        ) { [self, unowned kernel] in
            showHotlist(in: kernel)
        }
        commands.register(Command(.toggleHotlistEntry, "Add or Remove Current Directory in Hotlist")) {
            [self, unowned kernel] in
            toggleCurrentDirectory(at: [], in: kernel)
        }
        commands.register(Command(.configureHotlist, "Configure Directory Hotlist…")) { [self, unowned kernel] in
            configureHotlist(in: kernel)
        }
    }

    /// The menu items and toolbar buttons of the plugin.
    private func addButtons(in kernel: Kernel) {
        kernel.menus.add([.directoryTree, .directoryHotlist, .directoryHistory], to: .commandsPlaces)
        kernel.toolbar.add(
            .directoryHotlist,
            symbol: "star",
            group: 30,
            hint: "Your favourite folders: jump to one, or add the current folder."
        )
        kernel.toolbar.add(
            .directoryHistory,
            symbol: "clock.arrow.circlepath",
            group: 30,
            hint: "The folders you visited recently: jump back to one."
        )
        kernel.toolbar.add(
            .directoryTree,
            symbol: "folder.badge.gearshape",
            group: 30,
            hint: "Show all folders as a tree and jump to one."
        )
        kernel.toolbar.setSymbol("star.leadinghalf.filled", for: .toggleHotlistEntry)
        kernel.toolbar.setSymbol("star.square", for: .configureHotlist)
    }

    /// The "Hotlist and History" page of the preferences.
    private func addPreferences(in kernel: Kernel) {
        kernel.preferences.add(
            PreferencePage(
                title: "Hotlist and History",
                preferences: [
                    Preference(
                        Keys.favorites,
                        "Offer the Mac's standard folders (Favorites) in the directory hotlist",
                        .flag(default: true)
                    ),
                    Preference(
                        Keys.thinning,
                        "Directory history thinning: leave out folders that were only passed through",
                        .flag(default: true)
                    ),
                    Preference(Keys.saveHistory, "Save the directory history between sessions", .flag(default: true)),
                    Preference(Keys.historyShown, "Maximum history items to show:", .text(default: "26")),
                    Preference(
                        Keys.showFrequent,
                        "Show frequently used folders in the history list",
                        .flag(default: true)
                    ),
                    Preference(Keys.frequentShown, "Maximum frequently used folders to show:", .text(default: "30"))
                ]
            )
        )
    }

    // MARK: Following the panels

    /// The side of the history `panel` keeps.
    internal func side(of panel: any PanelHandle, in kernel: Kernel) -> DirectoryHistoryTracker.Side {
        panel === kernel.panels.right ? .right : .left
    }

    /// A panel shows another directory: the history learns of it, and so does the tree cache.
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
                for: directory,
                places: provider.places(),
                providerRoot: provider.root(of: directory)
            )
            return DirectoryTree.relativePath(of: directory, below: root).map { ($0, root) }
        }
    }

    deinit {
        // Nothing to release.
    }
}
