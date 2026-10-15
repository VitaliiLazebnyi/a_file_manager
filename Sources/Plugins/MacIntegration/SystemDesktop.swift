import AppKit
import Quartz

/// The Mac's desktop itself: each request goes to the system as it is. The UI tests cover this;
/// unit tests use a recording desktop instead.
///
/// Unchecked `Sendable`: `open` and `reveal` only call `NSWorkspace`, which may be used from any
/// thread; `picker` is touched on the main thread only.
internal final class SystemDesktop: MacDesktop, @unchecked Sendable {
    /// The sharing panel on screen; kept for as long as it is shown.
    private var picker: NSSharingServicePicker?

    /// The system's shared Quick Look panel.
    @MainActor internal var preview: any PreviewPanel { SystemPreviewPanel() }

    /// Opens the files with the application.
    internal func open(_ urls: [URL], with application: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens the file with its own application.
    internal func open(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shows the items selected in Finder.
    internal func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Lets the user pick an application from the Applications folder.
    @MainActor
    internal func chooseApplication(title: String) -> URL? {
        let panel = NSOpenPanel()
        (panel.title, panel.directoryURL, panel.allowedContentTypes) = (
            title, URL(fileURLWithPath: "/Applications"), [.application]
        )
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Shows the sharing panel at the middle of the key window.
    @MainActor
    internal func share(_ urls: [URL]) {
        guard let view = NSApp?.keyWindow?.contentView else {
            return
        }
        let shown = NSSharingServicePicker(items: urls)
        picker = shown
        let middle = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        shown.show(relativeTo: middle, of: view, preferredEdge: .minY)
    }

    deinit {
        // Nothing to release.
    }
}
