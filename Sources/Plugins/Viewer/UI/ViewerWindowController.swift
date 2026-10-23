import AFMKernel
import AFMShell
import AppKit

/// A Lister window (spec 10 › The Lister window): one pane, and the files of the session to
/// step through with N and P.
///
/// Main thread only.
internal final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    /// The pane that shows the file, the window's content view.
    internal let pane: ViewerPane
    private let settings: ListerSettings
    private let onClose: (ViewerWindowController) -> Void
    /// The files of the session, in the order N steps through them.
    internal private(set) var items: [ViewerItem] = []
    /// Which of `items` is shown.
    internal private(set) var index = 0
    /// The separate quick view: it shows whatever the panel cursor is on, and its title is
    /// `Lister*` (spec 10 › Title bar).
    internal let followsCursor: Bool
    private var follower: CursorFollower?
    /// The window, which the controller keeps for as long as it lives.
    private let toolWindow: ToolWindow

    /// Makes the window, at its saved frame or centred, with nothing shown yet.
    ///
    /// `internalOnly` shows every file as text: no Quick Look, no images, no multimedia
    /// (`cm_ListInternalOnly`); `followsCursor` makes it the separate quick view, which shows what the source
    /// panel's cursor is on `followDelay` seconds after it moved. `onClose` runs when the window
    /// closes.
    internal init(
        kernel: Kernel,
        settings: ListerSettings,
        temporaryCopies: TemporaryCopies,
        internalOnly: Bool,
        followsCursor: Bool,
        followDelay: TimeInterval,
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
            follower = CursorFollower(
                kernel: kernel,
                delay: followDelay,
                panel: { kernel.panels.source },
                show: { [weak self] item in self?.follow(item) }
            )
        }
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    /// Shows the files of a session, the first one first.
    internal func show(_ items: [ViewerItem]) {
        self.items = items
        index = 0
        loadCurrent()
    }

    /// N / P: the next or the previous file; nothing happens at either end or with one file
    /// (spec 10 › Multi-file sessions).
    internal func step(by delta: Int) {
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
    internal func refreshFollowing() { follower?.refresh() }

    private func setTitle(_ text: String) {
        let name = followsCursor ? "Lister*" : "Lister"
        window?.title = text.isEmpty ? name : "\(name) - [\(text)]"
    }

    /// Options › Save position (spec 10 › Geometry); the separate quick view has a place of its own.
    internal func savePosition() {
        settings.setWindowFrame(NSStringFromRect(toolWindow.frame), quick: followsCursor)
    }

    /// Saves the frame, stops following and reading, and tells the owner the window is gone.
    internal func windowWillClose(_: Notification) {
        savePosition()
        follower = nil
        pane.stopWork()
        onClose(self)
    }
}
