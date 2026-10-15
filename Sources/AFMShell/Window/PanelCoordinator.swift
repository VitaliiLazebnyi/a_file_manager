import AFMContracts
import AFMKernel
import AppKit

/// The two panels of the main window.
///
/// Which one is the source, keeping them up to date with changes made by other programs, and
/// reading ahead the folder under the source panel's cursor. Main thread only.
internal final class PanelCoordinator: PanelSet, PanelHost {
    /// The settings keys of the left and the right panel's tabs.
    private static let stateKeys = ["left.tabs", "right.tabs"]

    /// The left panel.
    internal let leftPanel: PanelViewController
    /// The right panel.
    internal let rightPanel: PanelViewController
    /// The places of the volume lists and the drive buttons.
    internal let places: PlacesStore
    /// Reads ahead the folder under the source panel's cursor.
    internal let readAhead: ReadAhead
    /// The panel the user works in; the other one is the target.
    internal private(set) var sourcePanel: PanelViewController
    /// Called when a panel started or stopped reading and nothing else changed.
    internal var onActivityChanged: (() -> Void)?
    /// Refreshing waits while this is true (a job is running; the panels are re-read when it ends).
    internal var isPaused: () -> Bool = { false }
    /// Whether the main window is the one the user works in; nothing is read ahead while it is not.
    ///
    /// The shell says how to tell.
    internal var isWindowActive: () -> Bool = { false }
    /// The kernel whose settings, file systems and events the panels use.
    private let kernel: Kernel
    /// The user's switch for reading ahead (`ReadAhead.settingsKey`).
    private let readsAhead: Bool
    /// The folders the panels show, watched for changes.
    private lazy var watches = FolderWatches(fileSystems: kernel.fileSystems) { [weak self] changed in
        self?.reload(changed, changedAt: nil)
    }
    /// Changes reported while a job was running.
    private var missedChanges = MissedChanges()

    /// The left panel, for the plugins.
    internal var left: any PanelHandle { leftPanel }
    /// The right panel, for the plugins.
    internal var right: any PanelHandle { rightPanel }
    /// The source panel, for the plugins.
    internal var source: any PanelHandle { sourcePanel }
    /// The target panel, for the plugins.
    internal var target: any PanelHandle { targetPanel }
    /// The panel that is not the source.
    internal var targetPanel: PanelViewController { sourcePanel === leftPanel ? rightPanel : leftPanel }
    /// Both panels, left first.
    private var panels: [PanelViewController] { [leftPanel, rightPanel] }

    /// The panels of `kernel`, as they were left; `home` is where a panel starts when it has no
    /// folder from the last session, or when that folder is gone.
    internal init(kernel: Kernel, home: URL) {
        self.kernel = kernel
        readAhead = ReadAhead(fileSystems: kernel.fileSystems, cache: kernel.listingCache)
        places = PlacesStore(fileSystems: kernel.fileSystems)
        readsAhead = kernel.settings.value(Bool.self, forKey: ReadAhead.settingsKey) ?? true
        leftPanel = Self.makePanel(kernel: kernel, key: Self.stateKeys[0], home: home)
        rightPanel = Self.makePanel(kernel: kernel, key: Self.stateKeys[1], home: home)
        sourcePanel = leftPanel
        leftPanel.host = self
        rightPanel.host = self
        restoreViews()
        activate(leftPanel)
        // The folders of the last session are read in the background; one that is gone is
        // replaced by the home folder, and that by the root.
        for panel in panels {
            loadInitially(panel, candidates: [panel.model.directory, home, URL(fileURLWithPath: "/")])
        }
        places.observe { [weak self] in
            guard let self else {
                return
            }
            for panel in panels {
                panel.placesDidChange()
            }
        }
        // Nothing is watched yet: a folder is watched from the moment it has been listed.
    }

    /// The program does not connect to a server by itself when it starts.
    ///
    /// A tab that would (its file system says so, `connectsToServer`) is kept as it is, with
    /// its place, but is not the one in front: another tab of the panel is, or a new one at
    /// `home` when all of them would connect. The stored tabs are the user's own as a rule, but
    /// they can also come out of an imported settings file, and a start that hangs on a server
    /// that is gone or asks for a password before a window is there helps nobody. Going to the
    /// tab connects.
    internal static func keepFromConnectingAtStart(_ tabs: PanelTabs, home: URL, fileSystems: FileSystemRegistry) {
        func connects(_ tab: PanelModel) -> Bool {
            (try? fileSystems.provider(for: tab.directory))?.connectsToServer == true
        }
        guard connects(tabs.active) else {
            return
        }
        if let other = tabs.tabs.firstIndex(where: { !connects($0) }) {
            tabs.activate(other)
        } else {
            _ = tabs.insertTab(showing: home, at: 0, activate: true)
        }
    }

    /// The panel whose tabs are stored under `key`, with the tabs of the last session.
    private static func makePanel(kernel: Kernel, key: String, home: URL) -> PanelViewController {
        let state = kernel.settings.value(PanelTabs.State.self, forKey: key)
        let tabs = PanelTabs(restoring: state, fallback: home)
        keepFromConnectingAtStart(tabs, home: home, fileSystems: kernel.fileSystems)
        return PanelViewController(tabs: tabs, kernel: kernel)
    }

    /// Stops watching and reading, when the window goes away.
    internal func shutDown() {
        watches.shutDown()
        readAhead.shutDown()
        for panel in panels {
            panel.cancelLoading()
        }
    }

    /// Keeps the panels' tabs and views for the next start.
    internal func saveState() {
        kernel.settings.set(leftPanel.tabs.state, forKey: Self.stateKeys[0])
        kernel.settings.set(rightPanel.tabs.state, forKey: Self.stateKeys[1])
        for (panel, key) in zip(panels, PanelViewState.keys) {
            kernel.settings.set(panel.viewState, forKey: key)
        }
    }

    /// The user changed the options of the file lists: both panels take them over.
    internal func applySettings() {
        let settings = PanelSettings(from: kernel.settings)
        for panel in panels {
            panel.settings = settings
        }
    }

    /// An operation changed these directories: what is remembered of them is out of date.
    ///
    /// The panels that show one of them are re-read by `refresh` itself.
    internal func contentsChanged(in directories: [URL]) {
        kernel.listingCache.invalidate(directories)
    }

    /// Tells the read-ahead where the source panel's cursor is now.
    ///
    /// Called whenever that, or anything that decides whether reading ahead is allowed, may
    /// have changed.
    internal func updateReadAhead() {
        readAhead.cursorRests(on: readAheadTarget())
    }

    /// Picks up changes made by other programs in any folder, without redrawing what did not change.
    internal func reloadChangedPanels() {
        reload(.all, changedAt: nil)
    }

    /// Picks up changes made by other programs in `directories`.
    internal func reloadChangedPanels(showing directories: [URL]) {
        reload(.only(directories), changedAt: nil)
    }

    /// The last job ended: what changed behind the panels meanwhile is picked up now, and so is
    /// what the panels themselves had to put off.
    ///
    /// A folder the job's own completion is reading again already (after the changes were
    /// reported) is not read a second time for them.
    internal func jobsEnded() {
        if let missed = missedChanges.take() {
            reload(missed.changed, changedAt: missed.at)
        }
        for panel in panels {
            panel.rereadIfDirty()
        }
    }

    /// A panel was clicked or tabbed into: it becomes the source.
    internal func panelDidBecomeActive(_ panel: PanelViewController) {
        let wasSource = panel === sourcePanel
        activate(panel)
        if !wasSource {
            kernel.panelEvents.post(.becameSource, from: panel)
        }
    }

    /// A panel shows another folder.
    internal func panelDidChangeLocation(_ panel: PanelViewController) {
        updateWatchers()
        kernel.panelEvents.post(.locationChanged, from: panel)
    }

    /// A panel's cursor moved.
    internal func panelCursorDidChange(_ panel: PanelViewController) {
        if panel === sourcePanel {
            updateReadAhead()
        }
        updateWatchers()
        kernel.panelEvents.post(.cursorMoved, from: panel)
    }

    /// Reading started or stopped and the panel shows what it showed.
    ///
    /// The read-ahead and the watching follow, the buttons are checked, and the plugins are
    /// left in peace.
    internal func panelActivityDidChange(_ panel: PanelViewController) {
        if panel === sourcePanel {
            updateReadAhead()
        }
        updateWatchers()
        onActivityChanged?()
    }

    /// The places a volume list shows: what is known now; they are asked for again for the next time.
    internal func placesForVolumeList(of _: PanelViewController) -> [Place] {
        places.refresh()
        return places.all
    }

    /// The drive that can be ejected and holds `location`; nil for none.
    internal func ejectableVolume(containing location: URL) -> Place? {
        guard location.isFileURL else {
            return nil
        }
        let drives = places.all.filter(\.canBeEjected)
        return DriveBarView.currentPlace(among: drives, for: location).map { drives[$0] }
    }

    /// A panel's selection changed.
    internal func panelSelectionDidChange(_ panel: PanelViewController) {
        kernel.panelEvents.post(.selectionChanged, from: panel)
    }

    /// What the read-ahead has of `location`, for a panel that is about to read it.
    internal func panel(_: PanelViewController, joinReadingOf location: URL, showHidden: Bool) -> ReadAhead.Joined? {
        readAhead.join(location, showHidden: showHidden)
    }

    /// Each panel comes back in the view it was left in, with its columns and their widths.
    private func restoreViews() {
        let settings = PanelSettings(from: kernel.settings)
        for (panel, key) in zip(panels, PanelViewState.keys) {
            panel.settings = settings
            if let state = kernel.settings.value(PanelViewState.self, forKey: key) {
                panel.viewState = state
            }
            panel.onViewStateChanged = { [weak self, weak panel] in
                if let panel {
                    self?.kernel.settings.set(panel.viewState, forKey: key)
                }
            }
        }
    }

    /// Reads the first of `candidates` that can be read into `panel`.
    private func loadInitially(_ panel: PanelViewController, candidates: [URL]) {
        guard let first = candidates.first else {
            return
        }
        panel.load(
            first,
            in: panel.model,
            focus: nil,
            history: .keep,
            reportFailure: false
        ) { [weak self, weak panel] succeeded in
            // Not when the reading was overtaken by one the user started: that one decides.
            if let panel, !succeeded, !panel.isLoading, !panel.model.isListed {
                self?.loadInitially(panel, candidates: Array(candidates.dropFirst()))
            }
        }
    }

    /// Makes a panel the source; the other one becomes the target (spec 01 › Two panels).
    private func activate(_ panel: PanelViewController) {
        sourcePanel = panel
        leftPanel.isActive = panel === leftPanel
        rightPanel.isActive = panel === rightPanel
        updateReadAhead()
    }

    /// The folder under the source panel's cursor, when it may be read ahead.
    ///
    /// That is a real entry of a completely listed folder on a volume that is not local (not a
    /// file, not `[..]`, not a package), with the window active and neither a job nor a reading
    /// of the panel under way. Whether the volume is local is taken from the folder the panel
    /// shows, which was asked when it was read; nothing here touches a file system.
    private func readAheadTarget() -> ReadAhead.Target? {
        let model = sourcePanel.model
        guard readsAhead, isWindowActive(), !isPaused(), !sourcePanel.isLoading, model.isComplete,
            model.volume?.isLocal == false,
            let item = model.cursorItem, item.isFolder, kernel.listingCache.isEnabled
        else {
            return nil
        }
        return ReadAhead.Target(location: item.url, showHidden: model.showHidden, order: model.wantedSort)
    }

    /// Picks up the changes of `changed` without redrawing what did not change.
    ///
    /// `changedAt`: when the change was noticed (in the system's uptime), if that was a while
    /// ago; a folder whose reading began after that is not read once more. While a job runs the
    /// change is noted instead, and read when the job has ended (`jobsEnded`).
    private func reload(_ changed: ChangedFolders, changedAt: TimeInterval?) {
        guard !isPaused() else {
            missedChanges.note(changed, at: ProcessInfo.processInfo.systemUptime)
            return
        }
        for panel in panels where changed.concerns(panel.model.directory) {
            if let changedAt {
                panel.reloadForChange(at: changedAt)
            } else {
                panel.reload(focus: nil, quietly: true, completion: nil)
            }
        }
    }

    /// Has each file system watch the folders the panels show on it.
    ///
    /// Those that have been listed, each for itself. A panel that moves leaves the watch of the
    /// other alone.
    private func updateWatchers() {
        var wanted: [String: URL] = [:]
        for panel in panels where panel.model.isListed {
            wanted[panel.model.directory.locationKey] = panel.model.directory
        }
        watches.watch(wanted)
    }

    deinit {
        // Nothing to release: `shutDown` ends the watching and the reading.
    }
}
