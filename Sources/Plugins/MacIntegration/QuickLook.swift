import AFMKernel
import AppKit
import Quartz

/// Feeds the system's Quick Look panel with the files of the active panel.
///
/// The panel finds whoever feeds it in the responder chain of the main window, so this object puts
/// itself there, behind the window; keys the panel does not use go on to the file list, which lets
/// the cursor keys move through the folder while the preview follows. The panel itself is reached
/// through `PreviewPanel` (none in tests of the plugin that start nothing). Main thread only.
final class QuickLookController: NSResponder, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    private var urls: [URL] = []
    private weak var host: NSWindow?
    /// The panel this feeds; without one, nothing is ever shown.
    var panel: (any PreviewPanel)?

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the panel with these files, or closes it when it is open.
    func toggle(_ urls: [URL]) {
        if isVisible {
            panel?.close()
            return
        }
        guard !urls.isEmpty else {
            return
        }
        self.urls = urls
        panel?.show(for: self)
    }

    /// Puts this object behind `window` in the responder chain, where the panel looks for whoever
    /// feeds it; once, and not without a window.
    internal func join(_ window: NSWindow?) {
        if host == nil, let window {
            nextResponder = window.nextResponder
            window.nextResponder = self
            host = window
        }
    }

    /// Follows the cursor: the open panel shows other files.
    func follow(_ urls: [URL]) {
        guard isVisible, urls != self.urls else {
            return
        }
        self.urls = urls
        panel?.reload()
    }

    func close() {
        if isVisible { panel?.close() }
    }

    /// Closes the panel when it previews a file of `volume`.
    func close(ifShowing volume: URL) {
        if urls.contains(where: { $0.isSameLocation(as: volume) || $0.isInside(volume) }) { close() }
    }

    override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool { true }

    // The panel asks for control on the main thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let responder = host?.firstResponder, responder !== self else {
            return false
        }
        responder.keyDown(with: event)
        return true
    }
}
