import AppKit
import Quartz

/// The system's shared Quick Look panel. The UI tests cover this; unit tests use a panel of
/// their own.
@MainActor
internal final class SystemPreviewPanel: PreviewPanel {
    /// The shared panel, made when it is first asked for: there always is one.
    private var shared: QLPreviewPanel { QLPreviewPanel.shared() }

    /// Whether the shared panel exists and is on screen.
    internal var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && shared.isVisible
    }

    /// Shows the shared panel. It finds its feeder in the responder chain of the main window,
    /// which the feeder joined when the command started.
    internal func show(for _: QuickLookController) {
        shared.makeKeyAndOrderFront(nil)
        shared.reloadData()
    }

    /// Has the shared panel ask its feeder again.
    internal func reload() { shared.reloadData() }

    /// Takes the shared panel off the screen.
    internal func close() { shared.orderOut(nil) }

    deinit {
        // Nothing to release.
    }
}
