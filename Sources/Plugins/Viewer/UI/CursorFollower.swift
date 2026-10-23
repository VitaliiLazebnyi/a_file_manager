import AFMKernel
import Foundation

/// Follows the cursor of a panel for a quick view: every time the cursor, the folder or the
/// source panel changes it reports, a moment later, what the cursor is on.
///
/// Events that follow each other quickly (holding an arrow key) are answered once, for the last
/// one. Main thread only.
@MainActor
internal final class CursorFollower {
    private let delay: TimeInterval
    private let panel: () -> any PanelHandle?
    private let show: (FileItem?) -> Void
    private var subscription: AnyObject?
    private var generation = 0
    private var shown: FileItem??

    /// `panel` names the panel to follow at the time of each event; `show` receives the item
    /// under its cursor (nil on `[..]` or in an empty folder).
    internal init(
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
    internal func refresh() { schedule(force: true) }

    private func schedule(force: Bool) {
        generation += 1
        let wanted = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == wanted, let followed = panel() else {
                return
            }
            let item = followed.model.cursorItem
            if !force, let shown, shown == item {
                return
            }
            shown = .some(item)
            show(item)
        }
    }

    deinit {
        // Nothing to release.
    }
}
