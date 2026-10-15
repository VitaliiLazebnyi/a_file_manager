public import AFMContracts
public import AFMKernel
public import AFMShell
public import AppKit

/// Commands only the viewer uses, by their names in the specification (17 › Command catalogue).
extension CommandID {
    /// Lister with the file under the cursor (Shift+F3).
    static let viewSingle: CommandID = "cm_ListOnly"
    /// Lister with the marked files.
    static let viewMarked: CommandID = "cm_ListMulti"
    /// Lister with text modes only: no images, multimedia or Quick Look (Alt+Shift+F3).
    static let viewInternalSingle: CommandID = "cm_ListInternalOnly"
    static let viewInternalMarked: CommandID = "cm_ListInternalMulti"
    static let quickViewInternalOnly: CommandID = "cm_SrcQuickInternalOnly"
    static let hideQuickView: CommandID = "cm_SrcHideQuickView"
    static let updateQuickView: CommandID = "cm_UpdateQuickView"
    static let separateQuickView: CommandID = "cm_SeparateQuickView"
    static let separateQuickViewInternalOnly: CommandID = "cm_SeparateQuickInternalOnly"
    static let configureLister: CommandID = "cm_ConfigLister"
}

/// Lister, the built-in viewer (spec 10), and the Quick View panel (spec 03 › Quick View).
/// Files are read through their file-system providers, so everything works in archives and on
/// servers as it does on the disk. The plugin and its windows live on the main thread; what
/// reads files runs in the background (see `ViewerPane`).
public final class ViewerPlugin: Plugin, ViewerService {
    public let name = "Viewer"
    private let overlayHost: (any PanelHandle) -> any PanelOverlayHost?
    private let quickViewDelay: TimeInterval
    private let showsWindows: Bool
    /// Weak: the kernel owns the plugin.
    private weak var owner: Kernel?
    private var settings: ListerSettings?
    private let temporaryCopies = TemporaryCopies()
    private(set) var windows: [ViewerWindowController] = []
    private(set) var quickView: QuickViewPanel?
    /// What the panes play sounds and films with: the system's player, or a test's that plays nothing.
    internal var mediaPlayback: @MainActor () -> any MediaPlayback = { SystemMediaPlayback() }
    /// Puts a Lister window on screen (with `showsWindows`). Tests replace it, so that no window
    /// shows in the session they run in, and look at what it was asked to show.
    internal var present: @MainActor (NSWindowController) -> Void = { $0.showWindow(nil) }

    /// `overlayHost` finds the part of a panel that can be covered by the quick view;
    /// `quickViewDelay` is how long the quick view waits for the cursor to rest before it
    /// loads a file; with `showsWindows` off, Lister windows are created but not put on
    /// screen (for tests).
    public init(
        overlayHost: @escaping (any PanelHandle) -> any PanelOverlayHost? = { $0 as? (any PanelOverlayHost) },
        quickViewDelay: TimeInterval = 0.12,
        showsWindows: Bool = true
    ) {
        self.overlayHost = overlayHost
        self.quickViewDelay = quickViewDelay
        self.showsWindows = showsWindows
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        self.owner = owner
        let listerSettings = ListerSettings(kernel.settings)
        settings = listerSettings
        let commands = kernel.commands
        kernel.fileSystems.addVolumeReleaser { [weak self] volume in self?.letGo(of: volume) }
        let model = { kernel.panels.source.model }
        let cursorFile = { model().cursorItem.flatMap { $0.isDirectory ? nil : $0.url } }
        /// The marked files, or without any the file under the cursor (spec 10 › Keys and commands).
        let markedFiles = { model().operands().filter { !$0.isDirectory }.map(\.url) }
        /// The toolbar asks `enabled` ten times a second, so it must not resolve the operands
        /// (an O(n) pass with items marked); `canView` is a cheap test, `files` runs with the command.
        func viewer(
            _ id: CommandID,
            _ title: String,
            _ shortcuts: [Shortcut],
            barLabel: String? = nil,
            internalOnly: Bool = false,
            canView: (() -> Bool)? = nil,
            files: @escaping () -> [URL]
        ) {
            commands.register(
                Command(id, title, shortcuts, barLabel: barLabel, runsDuringJobs: true),
                enabled: { canView?() ?? !files().isEmpty },
                parameterized: { [weak self] argument in
                    // Not empty: the command is enabled only when there are files.
                    let urls = argument.location.map { [$0] } ?? files()
                    self?
                        .open(
                            urls.map { ViewerItem(source: .file($0), title: kernel.fileSystems.displayPath($0)) },
                            internalOnly: internalOnly
                        )
                }
            )
        }
        // Something marked must be a file, or without marks the cursor must be on one (the list of files is made when the command runs).
        let canView = { model().hasOperandFile }
        viewer(.view, "View", [.f(3)], barLabel: "View", canView: canView, files: markedFiles)
        viewer(.viewSingle, "View File Under Cursor", [.f(3, .shift)]) { cursorFile().map { [$0] } ?? [] }
        viewer(.viewMarked, "View Marked Files", [], canView: canView, files: markedFiles)
        viewer(.viewInternalSingle, "View as Text Only", [.f(3, [.option, .shift])], internalOnly: true) {
            cursorFile().map { [$0] } ?? []
        }
        viewer(
            .viewInternalMarked,
            "View Marked Files as Text Only",
            [],
            internalOnly: true,
            canView: canView,
            files: markedFiles
        )

        let isOn = { [weak self] in self?.quickView != nil }
        commands.register(
            Command(.quickView, "Quick View Panel", [Shortcut(.character("q"), .control)], runsDuringJobs: true),
            checked: isOn
        ) { [weak self] in
            self?.toggleQuickView(internalOnly: false, kernel: kernel, settings: listerSettings)
        }
        commands.register(
            Command(.quickViewInternalOnly, "Quick View Panel, Text Only", runsDuringJobs: true),
            checked: isOn
        ) { [weak self] in
            self?.toggleQuickView(internalOnly: true, kernel: kernel, settings: listerSettings)
        }
        commands.register(Command(.hideQuickView, "Quick View Panel Off", runsDuringJobs: true), enabled: isOn) {
            [weak self] in self?.hideQuickView()
        }
        commands.register(
            Command(.updateQuickView, "Reload Quick View", runsDuringJobs: true),
            enabled: { [weak self] in self?.quickView != nil || self?.windows.contains(where: \.followsCursor) == true
            }
        ) { [weak self] in
            self?.quickView?.refresh()
            self?.windows.filter(\.followsCursor).forEach { $0.refreshFollowing() }
        }
        let separateIsOpen = { [weak self] in self?.windows.contains(where: \.followsCursor) == true }
        commands.register(
            Command(
                .separateQuickView,
                "Separate Quick View Window",
                [Shortcut(.character("q"), [.control, .shift])],
                runsDuringJobs: true
            ),
            checked: separateIsOpen
        ) { [weak self] in self?.toggleSeparateQuickView(internalOnly: false) }
        commands.register(
            Command(.separateQuickViewInternalOnly, "Separate Quick View Window, Text Only", runsDuringJobs: true),
            checked: separateIsOpen
        ) { [weak self] in self?.toggleSeparateQuickView(internalOnly: true) }
        commands.register(Command(.configureLister, "Configure Lister…", runsDuringJobs: true)) { [weak self] in
            self?.configure(kernel)
        }

        // The Files menu lists View only; the other ways of viewing have their keys.
        kernel.menus.add([.view], to: .filesOpen)
        kernel.menus.addToContextMenu([.view], in: .open, onItemOnly: true)
        kernel.menus.add([.quickView, .separateQuickView], to: .showViewType)
        kernel.toolbar.add(
            .view,
            symbol: "doc.text.magnifyingglass",
            group: 20,
            hint: "Open the selected file in the viewer."
        )
        kernel.toolbar.add(
            .quickView,
            symbol: "sidebar.right",
            group: 20,
            hint: "Show the file under the cursor in the other panel, as you move through the list."
        )
        kernel.toolbar.setSymbol("macwindow.on.rectangle", for: .separateQuickView)
        kernel.toolbar.setSymbol("gearshape", for: .configureLister)
        kernel.preferences.add(ListerSettings.preferencePage { [weak self] in self?.settingsChanged() })
        kernel.services.register((any ViewerService).self, self)
    }

    public func stop() {
        hideQuickView()
        windows.forEach { $0.close() }
        windows = []
        // Normally done by `prepareToQuit` already; what is left is deleted here, waiting a moment at most.
        temporaryCopies.removeAll()
    }

    /// Closes the windows and deletes the temporary copies of remote files in the background, so the
    /// program does not wait for the disk on the main thread when it quits.
    public func prepareToQuit(cancellation _: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        hideQuickView()
        windows.forEach { $0.close() }
        windows = []
        temporaryCopies.removeAll(waiting: false) { completion() }
    }

    // MARK: ViewerService

    public func view(_ url: URL) {
        guard let kernel = owner else { return }
        open([ViewerItem(source: .file(url), title: kernel.fileSystems.displayPath(url))], internalOnly: false)
    }

    public func view(text: String, title: String) {
        open([ViewerItem(source: .text(text), title: title)], internalOnly: false)
    }

    // MARK: Windows

    /// Opens a Lister window on the files of a session; it fills when the first has been read.
    @discardableResult
    func open(_ items: [ViewerItem], internalOnly: Bool, followsCursor: Bool = false) -> ViewerWindowController? {
        guard let kernel = owner, let settings else { return nil }
        let controller = ViewerWindowController(
            kernel: kernel,
            settings: settings,
            temporaryCopies: temporaryCopies,
            internalOnly: internalOnly,
            followsCursor: followsCursor,
            followDelay: quickViewDelay
        ) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        controller.pane.onConfigure = { [weak self] in self?.configure(kernel) }
        controller.pane.mediaPlayback = mediaPlayback
        // Several windows do not lie exactly on top of each other.
        if let last = windows.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        windows.append(controller)
        if showsWindows { present(controller) }
        if followsCursor { controller.refreshFollowing() } else { controller.show(items) }
        return controller
    }

    private func toggleSeparateQuickView(internalOnly: Bool) {
        if let open = windows.first(where: \.followsCursor) {
            open.close()
        } else {
            self.open([], internalOnly: internalOnly, followsCursor: true)
        }
    }

    // MARK: Quick View panel

    /// Ctrl+Q: covers the target panel with a viewer that follows the source panel's cursor;
    /// again, it brings the file list back (spec 03 › Quick View).
    private func toggleQuickView(internalOnly: Bool, kernel: Kernel, settings: ListerSettings) {
        guard quickView == nil else {
            hideQuickView()
            return
        }
        let source = kernel.panels.source
        let target = kernel.panels.target
        guard let host = overlayHost(target) else {
            kernel.commands.onRejected()
            return
        }
        quickView = QuickViewPanel(
            kernel: kernel,
            settings: settings,
            temporaryCopies: temporaryCopies,
            host: host,
            covering: target,
            following: source,
            internalOnly: internalOnly,
            delay: quickViewDelay
        ) { [weak self] in self?.hideQuickView() }
        quickView?.pane.onConfigure = { [weak self] in self?.configure(kernel) }
        quickView?.pane.mediaPlayback = mediaPlayback
    }

    /// Before `volume` is ejected: the Lister windows that show one of its files close, and a
    /// quick view of one shows nothing until the cursor moves on.
    func letGo(of volume: URL) {
        func isOnVolume(_ url: URL?) -> Bool {
            guard let url, url.isFileURL else { return false }
            return url.isSameLocation(as: volume) || url.isInside(volume)
        }
        for window in windows
        where isOnVolume(window.pane.item?.url) || window.items.contains(where: { isOnVolume($0.url) }) {
            window.pane.clear()
            window.close()
        }
        if let quickView, isOnVolume(quickView.pane.item?.url) || isOnVolume(quickView.shownItem?.url) {
            quickView.pane.clear()
        }
    }

    private func hideQuickView() {
        let panel = quickView
        quickView = nil
        panel?.remove()
    }

    // MARK: Configuration

    /// Configure Lister (spec 10 › Configure Lister): the options of the preference page as
    /// one dialog, for the command and for Options › Configure… in a Lister window.
    private func configure(_ kernel: Kernel) {
        let preferences = ListerSettings.preferences
        let store = kernel.settings
        let fields = preferences.map { preference -> FormField in
            switch preference.kind {
            case .flag(let value):
                return .checkbox(preference.key, preference.label, store.flag(preference.key, default: value))

            case .choice(let options, let value):
                return .choice(
                    preference.key,
                    preference.label,
                    options,
                    selected: store.index(preference.key, default: value)
                )

            case .text(let value):
                return .text(preference.key, preference.label, store.text(preference.key, default: value))
            }
        }
        guard let answer = kernel.interaction.form("Configure Lister", detail: "", fields: fields, buttons: ["OK"])
        else {
            return
        }
        for preference in preferences {
            if let value = answer.values[preference.key] { kernel.settings.set(value, for: preference) }
        }
        settingsChanged()
    }

    private func settingsChanged() {
        windows.forEach { $0.pane.applySettings() }
        quickView?.pane.applySettings()
    }
}
