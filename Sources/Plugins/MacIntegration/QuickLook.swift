import AppKit
import Quartz

/// The system's Quick Look panel for the files of the active panel. The panel finds whoever
/// feeds it in the responder chain of the main window, so this object puts itself there, behind
/// the window; keys the panel does not use go on to the file list, which lets the cursor keys
/// move through the folder while the preview follows. Main thread only.
final class QuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []
    private weak var host: NSWindow?

    private var visiblePanel: QLPreviewPanel? {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else {
            return nil
        }
        return panel
    }

    var isVisible: Bool { visiblePanel != nil }

    /// Shows the panel with these files, or closes it when it is open.
    func toggle(_ urls: [URL]) {
        if let panel = visiblePanel { return panel.orderOut(nil) }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        if host == nil, let window = NSApp.mainWindow {
            nextResponder = window.nextResponder
            window.nextResponder = self
            host = window
        }
        if host == nil {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    /// Follows the cursor: the open panel shows other files.
    func follow(_ urls: [URL]) {
        guard let panel = visiblePanel, urls != self.urls else { return }
        self.urls = urls
        panel.reloadData()
    }

    func close() {
        visiblePanel?.orderOut(nil)
    }

    /// Closes the panel when it previews a file of `volume`.
    func close(ifShowing volume: URL) {
        if isVisible, urls.contains(where: { $0.isSameLocation(as: volume) || $0.isInside(volume) }) { close() }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let responder = host?.firstResponder, responder !== self else {
            return false
        }
        responder.keyDown(with: event)
        return true
    }
}
