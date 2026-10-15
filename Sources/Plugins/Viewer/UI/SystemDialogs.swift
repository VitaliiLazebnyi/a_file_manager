import AppKit
import PDFKit

/// The system's panels, printing and window changes, each a call or two that hand over to AppKit.
@MainActor
internal struct SystemDialogs: ViewerDialogs {
    /// The open panel, for files only.
    internal func fileToOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The save panel.
    internal func saveTarget(proposing name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The page layout panel.
    internal func pageLayout(_ info: NSPrintInfo) -> Bool {
        NSPageLayout().runModal(with: info) == NSApplication.ModalResponse.OK.rawValue
    }

    /// The print panel, as a sheet when there is a window.
    internal func run(_ operation: NSPrintOperation, for window: NSWindow?) {
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// The print panel of the PDF view.
    internal func print(_ view: PDFView, with info: NSPrintInfo) {
        view.print(with: info, autoRotate: true)
    }

    /// Full screen.
    internal func toggleFullScreen(_ window: NSWindow?) {
        window?.toggleFullScreen(nil)
    }

    /// The window's zoom.
    internal func zoom(_ window: NSWindow?) {
        window?.zoom(nil)
    }
}
