import AFMKernel
import AFMShell
import AppKit

/// The Quick View panel (spec 03 › Quick View, 10 › Embedded Lister): a Lister over the file
/// list of the other panel that shows whatever the cursor of the followed panel is on. A bar
/// above it names the file; for a folder the pane tells what it holds.
///
/// It goes away when the user switches to the covered panel or shows another place in it
/// (`onDismiss`). Main thread only; the pane does its reading in the background and drops the
/// load of the item before when the cursor moves on.
final class QuickViewPanel {
    let pane: ViewerPane
    /// The panel whose list is covered.
    private(set) weak var covered: PanelHandle?
    /// The panel whose cursor is followed.
    private(set) weak var followed: PanelHandle?
    private weak var host: PanelOverlayHost?
    private let container = NSView()
    private let header = NSTextField(labelWithString: "")
    private var follower: CursorFollower?
    private var subscription: AnyObject?
    private let kernel: Kernel
    /// What the bar above the pane says.
    private(set) var headerText = "" { didSet { header.stringValue = headerText } }
    /// The item that is shown, as the followed panel lists it.
    private(set) var shownItem: FileItem?

    init(
        kernel: Kernel, settings: ListerSettings, temporaryCopies: TemporaryCopies, host: PanelOverlayHost,
        covering covered: PanelHandle,
        following followed: PanelHandle, internalOnly: Bool, delay: TimeInterval, onDismiss: @escaping () -> Void
    ) {
        self.kernel = kernel
        self.host = host
        self.covered = covered
        self.followed = followed
        pane = ViewerPane(kernel: kernel, settings: settings, temporaryCopies: temporaryCopies, isEmbedded: true)
        pane.internalOnly = internalOnly
        build()
        host.overlay = container
        pane.onTitleChange = { [weak self] title in
            // A track that names itself replaces the file name (spec 10 › Embedded Lister).
            guard let self, let item = shownItem, title != self.kernel.fileSystems.displayPath(item.url) else {
                return
            }
            headerText = title
        }
        follower = CursorFollower(kernel: kernel, delay: delay, panel: { [weak self] in self?.followed }) {
            [weak self] in self?.show($0)
        }
        subscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            guard let self, panel === self.covered else { return }
            // Switching to the covered panel, or showing another place in it, ends the quick view.
            if event == .becameSource || event == .locationChanged { onDismiss() }
        }
        follower?.refresh()
    }

    private func build() {
        header.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        header.lineBreakMode = .byTruncatingMiddle
        header.translatesAutoresizingMaskIntoConstraints = false
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(header)
        container.addSubview(pane)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            pane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }

    private func show(_ item: FileItem?) {
        shownItem = item
        guard let item else {
            headerText = ""
            pane.clear()
            return
        }
        headerText = item.name
        if item.isFolder {
            pane.showFolder(item.url, name: item.name)
        } else {
            pane.load(ViewerItem(source: .file(item.url), title: kernel.fileSystems.displayPath(item.url)))
        }
    }

    /// Reads the shown item again (`cm_UpdateQuickView`).
    func refresh() { follower?.refresh() }

    /// Brings the file list back. Safe to call more than once.
    func remove() {
        follower = nil
        subscription = nil
        pane.stopWork()
        // The keyboard goes back to the list that was followed.
        if pane.hasKeyboard { followed?.focus() }
        if host?.overlay === container { host?.overlay = nil }
    }
}
