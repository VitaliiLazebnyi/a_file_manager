import AFMKernel
import AFMShell
import AppKit

/// A Lister window (spec 10 › The Lister window): one pane, and the files of the session to
/// step through with N and P.
///
/// Main thread only.
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    let pane: ViewerPane
    private let settings: ListerSettings
    private let onClose: (ViewerWindowController) -> Void
    private(set) var items: [ViewerItem] = []
    private(set) var index = 0
    /// The separate quick view: it shows whatever the panel cursor is on, and its title is
    /// `Lister*` (spec 10 › Title bar).
    let followsCursor: Bool
    private var follower: CursorFollower?
    /// The window, which the controller keeps for as long as it lives.
    private let toolWindow: ToolWindow

    init(
        kernel: Kernel,
        settings: ListerSettings,
        temporaryCopies: TemporaryCopies,
        internalOnly: Bool = false,
        followsCursor: Bool = false,
        followDelay: TimeInterval = 0.12,
        onClose: @escaping (ViewerWindowController) -> Void
    ) {
        self.settings = settings
        self.onClose = onClose
        self.followsCursor = followsCursor
        pane = ViewerPane(kernel: kernel, settings: settings, temporaryCopies: temporaryCopies, isEmbedded: false)
        pane.internalOnly = internalOnly
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 220)
        window.title = followsCursor ? "Lister*" : "Lister"
        window.contentView = pane
        toolWindow = window
        if let saved = settings.windowFrame(quick: followsCursor) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }
        super.init(window: window)
        window.delegate = self
        // Esc is the pane's: it stops a search first and closes the window otherwise.
        window.onEscape = { [weak self] in
            guard let self else {
                return false
            }
            if pane.activity != nil {
                pane.activity?.cancel.cancel()
                return true
            }
            return false
        }
        pane.onClose = { [weak self] in self?.close() }
        pane.onStep = { [weak self] in self?.step(by: $0) }
        pane.onTitleChange = { [weak self] in self?.setTitle($0) }
        pane.onSavePosition = { [weak self] in self?.savePosition() }
        if followsCursor {
            follower = CursorFollower(kernel: kernel, delay: followDelay, panel: { kernel.panels.source }) {
                [weak self] item in
                self?.follow(item)
            }
        }
    }

    /// Made in code only: an archive gives none.
    required init?(coder _: NSCoder) { nil }

    /// Shows the files of a session, the first one first.
    func show(_ items: [ViewerItem]) {
        self.items = items
        index = 0
        loadCurrent()
    }

    /// N / P: the next or the previous file; nothing happens at either end or with one file
    /// (spec 10 › Multi-file sessions).
    func step(by delta: Int) {
        let target = index + delta
        guard items.indices.contains(target), target != index else {
            return
        }
        index = target
        loadCurrent()
    }

    private func loadCurrent() {
        pane.fileCounter = (index, max(1, items.count))
        guard items.indices.contains(index) else {
            return
        }
        pane.load(items[index])
    }

    /// The separate quick view was told what the panel cursor is on now.
    private func follow(_ item: FileItem?) {
        guard let item else {
            pane.clear()
            setTitle("")
            return
        }
        let title = pane.kernel.fileSystems.displayPath(item.url)
        if item.isFolder {
            pane.showFolder(item.url, name: item.name)
            setTitle(title)
        } else {
            show([ViewerItem(source: .file(item.url), title: title)])
        }
    }

    /// Reads what the panel cursor is on again (`cm_UpdateQuickView`).
    func refreshFollowing() { follower?.refresh() }

    private func setTitle(_ text: String) {
        let name = followsCursor ? "Lister*" : "Lister"
        window?.title = text.isEmpty ? name : "\(name) - [\(text)]"
    }

    /// Options › Save position (spec 10 › Geometry); the separate quick view has a place of its own.
    func savePosition() {
        settings.setWindowFrame(NSStringFromRect(toolWindow.frame), quick: followsCursor)
    }

    func windowWillClose(_: Notification) {
        savePosition()
        follower = nil
        pane.stopWork()
        onClose(self)
    }
}

/// Follows the cursor of a panel for a quick view: every time the cursor, the folder or the
/// source panel changes it reports, a moment later, what the cursor is on.
///
/// Events that follow each other quickly (holding an arrow key) are answered once, for the last
/// one. Main thread only.
@MainActor
final class CursorFollower {
    private let delay: TimeInterval
    private let panel: () -> any PanelHandle?
    private let show: (FileItem?) -> Void
    private var subscription: AnyObject?
    private var generation = 0
    private var shown: FileItem??

    /// `panel` names the panel to follow at the time of each event; `show` receives the item
    /// under its cursor (nil on `[..]` or in an empty folder).
    init(
        kernel: Kernel,
        delay: TimeInterval,
        panel: @escaping () -> any PanelHandle?,
        show: @escaping (FileItem?) -> Void
    ) {
        self.delay = delay
        self.panel = panel
        self.show = show
        subscription = kernel.panelEvents.subscribe { [weak self] _, source in
            guard let self, let followed = self.panel(), followed === source else {
                return
            }
            schedule(force: false)
        }
    }

    /// Reports the item under the cursor now, also when it is the one reported last.
    func refresh() { schedule(force: true) }

    private func schedule(force: Bool) {
        generation += 1
        let wanted = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == wanted, let panel = panel() else {
                return
            }
            let item = panel.model.cursorItem
            if !force, let shown, shown == item {
                return
            }
            shown = .some(item)
            show(item)
        }
    }
}
