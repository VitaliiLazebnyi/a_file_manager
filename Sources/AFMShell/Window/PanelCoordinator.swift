import AFMKernel
import AppKit

/// The two panels of the main window: which one is the source, keeping them up to date with
/// changes made by other programs, and reading ahead the folder under the source panel's
/// cursor. Main thread only.
final class PanelCoordinator: PanelSet, PanelHost {
    let leftPanel: PanelViewController
    let rightPanel: PanelViewController
    private let kernel: Kernel
    private(set) var sourcePanel: PanelViewController
    /// The folders that are watched or about to be, by location.
    private var watches: [String: Watch] = [:]
    private var watchedLocations: Set<String> = []
    private var isShutDown = false
    /// The places of the volume lists and the drive buttons.
    let places: PlacesStore
    /// Called when a panel started or stopped reading and nothing else changed.
    var onActivityChanged: (() -> Void)?
    /// Refreshing waits while this is true (a job is running; the panels are re-read when it ends).
    var isPaused: () -> Bool = { false }
    /// Whether the main window is the one the user works in; nothing is read ahead while it is
    /// not. The shell says how to tell.
    var isWindowActive: () -> Bool = { false }
    let readAhead: ReadAhead
    /// The user's switch for reading ahead (`ReadAhead.settingsKey`).
    private let readsAhead: Bool

    private static let stateKeys = ["left.tabs", "right.tabs"]

    /// `home` is where a panel starts when it has no folder from the last session, or when
    /// that folder is gone.
    init(kernel: Kernel, home: URL) {
        self.kernel = kernel
        readAhead = ReadAhead(fileSystems: kernel.fileSystems, cache: kernel.listingCache)
        places = PlacesStore(fileSystems: kernel.fileSystems)
        readsAhead = kernel.settings.value(Bool.self, forKey: ReadAhead.settingsKey) ?? true
        func makePanel(_ key: String) -> PanelViewController {
            let state = kernel.settings.value(PanelTabs.State.self, forKey: key)
            let tabs = PanelTabs(restoring: state, fallback: home)
            Self.keepFromConnectingAtStart(tabs, home: home, fileSystems: kernel.fileSystems)
            return PanelViewController(tabs: tabs, kernel: kernel)
        }
        leftPanel = makePanel(Self.stateKeys[0])
        rightPanel = makePanel(Self.stateKeys[1])
        sourcePanel = leftPanel
        leftPanel.host = self
        rightPanel.host = self
        // Each panel comes back in the view it was left in, with its columns and their widths.
        let settings = PanelSettings(from: kernel.settings)
        for (panel, key) in zip([leftPanel, rightPanel], PanelViewState.keys) {
            panel.settings = settings
            if let state = kernel.settings.value(PanelViewState.self, forKey: key) { panel.viewState = state }
            panel.onViewStateChanged = { [weak self, weak panel] in
                if let panel { self?.kernel.settings.set(panel.viewState, forKey: key) }
            }
        }
        activate(leftPanel)
        // The folders of the last session are read in the background; one that is gone is
        // replaced by the home folder, and that by the root.
        for panel in panels {
            loadInitially(panel, candidates: [panel.model.directory, home, URL(fileURLWithPath: "/")])
        }
        places.observe { [weak self] in self?.panels.forEach { $0.placesDidChange() } }
        // Nothing is watched yet: a folder is watched from the moment it has been listed.
    }

    /// The program does not connect to a server by itself when it starts. A tab that would
    /// (its file system says so, `connectsToServer`) is kept as it is, with its place, but is
    /// not the one in front: another tab of the panel is, or a new one at `home` when all of
    /// them would connect. The stored tabs are the user's own as a rule, but they can also
    /// come out of an imported settings file, and a start that hangs on a server that is gone
    /// or asks for a password before a window is there helps nobody. Going to the tab connects.
    static func keepFromConnectingAtStart(_ tabs: PanelTabs, home: URL, fileSystems: FileSystemRegistry) {
        func connects(_ tab: PanelModel) -> Bool {
            (try? fileSystems.provider(for: tab.directory))?.connectsToServer == true
        }
        guard connects(tabs.active) else { return }
        if let other = tabs.tabs.firstIndex(where: { !connects($0) }) {
            tabs.activate(other)
        } else {
            _ = tabs.insertTab(showing: home, at: 0, activate: true)
        }
    }

    private func loadInitially(_ panel: PanelViewController, candidates: [URL]) {
        guard let first = candidates.first else { return }
        panel.load(first, in: panel.model, focus: nil, history: .keep, reportFailure: false) {
            [weak self, weak panel] succeeded in
            // Not when the reading was overtaken by one the user started: that one decides.
            if let panel, !succeeded, !panel.isLoading, !panel.model.isListed {
                self?.loadInitially(panel, candidates: Array(candidates.dropFirst()))
            }
        }
    }

    // MARK: PanelSet

    var left: any PanelHandle { leftPanel }
    var right: any PanelHandle { rightPanel }
    var source: any PanelHandle { sourcePanel }
    var target: any PanelHandle { targetPanel }

    var targetPanel: PanelViewController { sourcePanel === leftPanel ? rightPanel : leftPanel }
    private var panels: [PanelViewController] { [leftPanel, rightPanel] }

    /// Makes a panel the source; the other one becomes the target (spec 01 › Two panels).
    private func activate(_ panel: PanelViewController) {
        sourcePanel = panel
        leftPanel.isActive = panel === leftPanel
        rightPanel.isActive = panel === rightPanel
        updateReadAhead()
    }

    /// Stops watching and reading, when the window goes away.
    func shutDown() {
        isShutDown = true
        for watch in watches.values {
            watch.isWanted = false
            Background.release(&watch.watcher)
        }
        watches = [:]
        watchedLocations = []
        readAhead.shutDown()
        panels.forEach { $0.cancelLoading() }
    }

    func saveState() {
        kernel.settings.set(leftPanel.tabs.state, forKey: Self.stateKeys[0])
        kernel.settings.set(rightPanel.tabs.state, forKey: Self.stateKeys[1])
        for (panel, key) in zip(panels, PanelViewState.keys) { kernel.settings.set(panel.viewState, forKey: key) }
    }

    /// The user changed the options of the file lists: both panels take them over.
    func applySettings() {
        let settings = PanelSettings(from: kernel.settings)
        panels.forEach { $0.settings = settings }
    }

    /// An operation changed these directories: what is remembered of them is out of date.
    /// The panels that show one of them are re-read by `refresh` itself.
    func contentsChanged(in directories: [URL]) {
        kernel.listingCache.invalidate(directories)
    }

    // MARK: Reading ahead

    /// Tells the read-ahead where the source panel's cursor is now. Called whenever that, or
    /// anything that decides whether reading ahead is allowed, may have changed.
    func updateReadAhead() {
        readAhead.cursorRests(on: readAheadTarget())
    }

    /// The folder under the source panel's cursor, when it may be read ahead: a real entry of a
    /// completely listed folder on a volume that is not local (not a file, not `[..]`, not a
    /// package), with the window active and neither a job nor a reading of the panel under way.
    /// Whether the volume is local is taken from the folder the panel shows, which was asked
    /// when it was read; nothing here touches a file system.
    private func readAheadTarget() -> ReadAhead.Target? {
        let model = sourcePanel.model
        guard readsAhead, isWindowActive(), !isPaused(), !sourcePanel.isLoading, model.isComplete,
            model.volume?.isLocal == false,
            let item = model.cursorItem, item.isFolder, kernel.listingCache.isEnabled
        else { return nil }
        return ReadAhead.Target(location: item.url, showHidden: model.showHidden, order: model.wantedSort)
    }

    // MARK: Refreshing

    /// Picks up changes made by other programs, without redrawing what did not change.
    /// `changedAt`: when the change was noticed (in the system's uptime), if that was a while
    /// ago; a folder whose reading began after that is not read once more.
    func reloadChangedPanels(showing directories: [URL]? = nil, changedAt: TimeInterval? = nil) {
        guard !isPaused() else {
            // Not forgotten: the panels are read when the job has ended (`jobsEnded`).
            if let directories, var missed = missedChanges {
                for directory in directories { missed[directory.locationKey] = directory }
                // Each folder is noted once however often it is reported; beyond a handful of
                // folders everything is simply looked at again.
                missedChanges = missed.count > Self.missedLimit ? nil : missed
            } else {
                missedChanges = nil
            }
            hasMissedChanges = true
            lastMissed = ProcessInfo.processInfo.systemUptime
            return
        }
        for panel in panels {
            let isAffected = directories?.contains { $0.isSameLocation(as: panel.model.directory) } ?? true
            guard isAffected else { continue }
            if let changedAt {
                panel.reloadForChange(at: changedAt)
            } else {
                panel.reload(focus: nil, quietly: true, completion: nil)
            }
        }
    }

    /// Changes reported while a job was running, to be read when it has ended: the folders
    /// reported, by location, or nil when everything has to be looked at again.
    private var missedChanges: [String: URL]? = [:]
    private var hasMissedChanges = false
    /// When the last of them was reported.
    private var lastMissed: TimeInterval = 0
    static let missedLimit = 64

    /// The last job ended: what changed behind the panels meanwhile is picked up now, and so is
    /// what the panels themselves had to put off. A folder the job's own completion is reading
    /// again already (after the changes were reported) is not read a second time for them.
    func jobsEnded() {
        if hasMissedChanges {
            let directories = missedChanges.map { Array($0.values) }
            (missedChanges, hasMissedChanges) = ([:], false)
            reloadChangedPanels(showing: directories, changedAt: lastMissed)
        }
        panels.forEach { $0.rereadIfDirty() }
    }

    // MARK: Watching

    /// One watched folder, from the moment watching it is asked of its file system.
    @MainActor private final class Watch {
        let directory: URL
        /// What the file system returned; watching ends when it is let go of.
        var watcher: (any WatchToken)?
        /// The file system has not come back from setting the watch up.
        var isStarting = true
        /// A panel shows the folder. A watch that is no longer wanted while it is still being
        /// set up stays in the table until its file system has come back, so that no second
        /// one is ever asked for behind it.
        var isWanted = true

        init(directory: URL) { self.directory = directory }
    }

    /// When setting a watch up took longer than this, the folder is read once more: what
    /// changed meanwhile went unseen.
    static let slowWatch: TimeInterval = 0.5

    /// Has each file system watch the folders the panels show on it: those that have been
    /// listed, each for itself. A panel that moves leaves the watch of the other alone.
    ///
    /// Setting a watch up asks the file system about the folder (the local one resolves its
    /// real path), which on a share that has stopped answering takes as long as the share
    /// pleases. So it is done in the folder's lane (`Background`), never here; the main thread
    /// only notes what is wanted and takes the watch over when it is there, if it is still
    /// wanted then.
    private func updateWatchers() {
        guard !isShutDown else { return }
        var wanted: [String: URL] = [:]
        for panel in panels where panel.model.isListed {
            wanted[panel.model.directory.locationKey] = panel.model.directory
        }
        guard Set(wanted.keys) != watchedLocations else { return }
        watchedLocations = Set(wanted.keys)
        for (key, watch) in watches where wanted[key] == nil {
            watch.isWanted = false
            guard !watch.isStarting else { continue }
            watches[key] = nil
            // Ending a watch is the file system's business too: not on this thread.
            Background.release(&watch.watcher)
        }
        for (key, directory) in wanted {
            if let watch = watches[key] {
                // Still there, or still being set up: taken up again.
                watch.isWanted = true
                continue
            }
            guard let provider = try? kernel.fileSystems.provider(for: directory) else { continue }
            let watch = Watch(directory: directory)
            watches[key] = watch
            start(watch, at: key, with: provider)
        }
    }

    private func start(_ watch: Watch, at key: String, with provider: any FileSystemProvider) {
        let directory = watch.directory
        let began = ProcessInfo.processInfo.systemUptime
        // The background takes nothing along that belongs to the main thread, only two weak
        // references for the file system's callback.
        Background.storage(
            "watch", at: directory, qos: .utility,
            work: { [weak self, weak watch] () -> (any WatchToken)? in
                provider.watch([directory]) { [weak self, weak watch] changed in
                    // Main thread, as the file system promises.
                    guard let self, let watch, watch.isWanted, watches[key] === watch else { return }
                    reloadChangedPanels(showing: changed)
                }
            },
            then: { [weak self] watcher in
                var watcher = watcher
                watch.isStarting = false
                guard let self, !isShutDown, watches[key] === watch else {
                    return Background.release(&watcher)
                }
                guard watch.isWanted else {
                    watches[key] = nil
                    return Background.release(&watcher)
                }
                watch.watcher = watcher
                if ProcessInfo.processInfo.systemUptime - began > Self.slowWatch {
                    reloadChangedPanels(showing: [directory])
                }
            })
    }

    // MARK: PanelHost

    func panelDidBecomeActive(_ panel: PanelViewController) {
        let wasSource = panel === sourcePanel
        activate(panel)
        if !wasSource { kernel.panelEvents.post(.becameSource, from: panel) }
    }

    func panelDidChangeLocation(_ panel: PanelViewController) {
        updateWatchers()
        kernel.panelEvents.post(.locationChanged, from: panel)
    }

    func panelCursorDidChange(_ panel: PanelViewController) {
        if panel === sourcePanel { updateReadAhead() }
        updateWatchers()
        kernel.panelEvents.post(.cursorMoved, from: panel)
    }

    /// Reading started or stopped and the panel shows what it showed: the read-ahead and the
    /// watching follow, the buttons are checked, and the plugins are left in peace.
    func panelActivityDidChange(_ panel: PanelViewController) {
        if panel === sourcePanel { updateReadAhead() }
        updateWatchers()
        onActivityChanged?()
    }

    func placesForVolumeList(of _: PanelViewController) -> [Place] {
        // Asked again for the next time; what is known is shown now.
        places.refresh()
        return places.all
    }

    func ejectableVolume(containing location: URL) -> Place? {
        guard location.isFileURL else { return nil }
        let drives = places.all.filter(\.canBeEjected)
        return DriveBarView.currentPlace(among: drives, for: location).map { drives[$0] }
    }

    func panelSelectionDidChange(_ panel: PanelViewController) {
        kernel.panelEvents.post(.selectionChanged, from: panel)
    }

    func panel(_: PanelViewController, joinReadingOf location: URL, showHidden: Bool) -> ReadAhead.Joined? {
        readAhead.join(location, showHidden: showHidden)
    }
}

/// The places the file systems offer for the volume lists and the drive buttons.
///
/// A file system is to answer `places()` at once, but one that has to look at its volumes
/// first may take its time, so the main thread never asks: each file system is asked on a
/// thread of the kernel's for calls that block (`BlockingCalls`), one question at a time, and
/// the list here is what they answered last. Asked again when volumes come and go, when a file system says its places changed,
/// and whenever a volume list is opened. Main thread only.
@MainActor
final class PlacesStore {
    /// Posted by a file system (the object) when its places are no longer what it answered.
    static let placesDidChange = Notification.Name("AFMPlacesDidChange")

    private let providers: [any FileSystemProvider]
    private var answers: [[Place]]
    private var asking: Set<Int> = []
    private var askAgain: Set<Int> = []
    private var handlers: [() -> Void] = []
    /// Filled in `init`, emptied in `deinit`.
    nonisolated(unsafe) private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    /// Every place, in the order of the file systems.
    private(set) var all: [Place] = []
    /// True once every file system has answered at least once.
    private(set) var isComplete = false
    private var answered: Set<Int> = []

    init(fileSystems: FileSystemRegistry) {
        providers = fileSystems.all
        answers = Array(repeating: [], count: providers.count)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ] {
            observers.append(
                (
                    workspace,
                    workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        // Delivered on the main queue.
                        MainActor.assumeIsolated { self?.refresh() }
                    }
                ))
        }
        let center = NotificationCenter.default
        observers.append(
            (
                center,
                center.addObserver(forName: Self.placesDidChange, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            ))
        refresh()
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    /// `handler` is called on the main thread whenever `all` has changed.
    func observe(_ handler: @escaping () -> Void) {
        handlers.append(handler)
    }

    /// Asks every file system for its places again. One that has not answered the last
    /// question yet is asked once more when it has.
    func refresh() {
        MainThread.assert("The places")
        if providers.isEmpty { isComplete = true }
        for index in providers.indices { ask(index) }
    }

    private func ask(_ index: Int) {
        guard asking.insert(index).inserted else {
            askAgain.insert(index)
            return
        }
        let provider = providers[index]
        // On one of the kernel's threads for calls that block; one question per file system
        // is out at a time, whoever asks.
        BlockingCalls.answer(
            from: provider as AnyObject, to: "places", { _ in provider.places() },
            then: { [weak self] (answer: [Place]?) in
                guard let self else { return }
                let places = answer ?? []
                asking.remove(index)
                answered.insert(index)
                let wasComplete = isComplete
                isComplete = answered.count == providers.count
                if !Self.areSame(places, answers[index]) || wasComplete != isComplete {
                    answers[index] = places
                    all = answers.flatMap { $0 }
                    handlers.forEach { $0() }
                }
                if askAgain.remove(index) != nil { ask(index) }
            })
    }

    private static func areSame(_ first: [Place], _ second: [Place]) -> Bool {
        first.count == second.count
            && zip(first, second).allSatisfy { $0.name == $1.name && $0.url == $1.url && $0.kind == $1.kind }
    }
}
