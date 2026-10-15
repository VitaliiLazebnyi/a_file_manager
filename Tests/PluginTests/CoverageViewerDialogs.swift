import AppKit
import PDFKit

@testable import ViewerPlugin

/// Answers the Lister's panels from a script and keeps what it would print, without showing
/// anything.
@MainActor
internal final class CoverageViewerDialogs: ViewerDialogs {
    /// What the open panel answers.
    internal var fileAnswer: URL?
    /// What the save panel answers.
    internal var saveAnswer: URL?
    /// What the page setup answers.
    internal var layoutAnswer = false
    /// The names the save panel proposed.
    internal private(set) var proposedNames: [String] = []
    /// The print operations that were run, with whether they had a window.
    internal private(set) var operations: [(operation: NSPrintOperation, hadWindow: Bool)] = []
    /// The PDF views that were printed.
    internal private(set) var printedPDFs: [PDFView] = []
    /// What was asked of the window: "full screen", "zoom".
    internal private(set) var windowChanges: [String] = []

    /// `fileAnswer`.
    internal func fileToOpen() -> URL? { fileAnswer }

    /// `saveAnswer`, keeping the proposed name.
    internal func saveTarget(proposing name: String) -> URL? {
        proposedNames.append(name)
        return saveAnswer
    }

    /// `layoutAnswer`.
    internal func pageLayout(_: NSPrintInfo) -> Bool { layoutAnswer }

    /// Keeps the operation.
    internal func run(_ operation: NSPrintOperation, for window: NSWindow?) {
        operations.append((operation, window != nil))
    }

    /// Keeps the view.
    internal func print(_ view: PDFView, with _: NSPrintInfo) {
        printedPDFs.append(view)
    }

    /// Notes it.
    internal func toggleFullScreen(_: NSWindow?) {
        windowChanges.append("full screen")
    }

    /// Notes it.
    internal func zoom(_: NSWindow?) {
        windowChanges.append("zoom")
    }

    deinit {
        // Nothing to release.
    }
}
