import AppKit
import Quartz

/// The system's shared Quick Look panel. The UI tests cover this; unit tests use a panel of
/// their own.
@MainActor
internal final class SystemPreviewPanel: PreviewPanel {
    /// Whether the shared panel exists and is on screen.
    internal var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// Shows the shared panel, fed through the main window's responder chain or directly.
    internal func show(for controller: QuickLookController) {
        guard let panel = QLPreviewPanel.shared() else {
            return
        }
        // Fed directly when there is no window whose responder chain could hold the feeder.
        if !controller.join(NSApp.mainWindow) {
            (panel.dataSource, panel.delegate) = (controller, controller)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    /// Has the shared panel ask its feeder again.
    internal func reload() { QLPreviewPanel.shared()?.reloadData() }

    /// Takes the shared panel off the screen.
    internal func close() { QLPreviewPanel.shared()?.orderOut(nil) }

    deinit {
        // Nothing to release.
    }
}
