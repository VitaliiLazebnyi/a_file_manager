import AppKit
import PDFKit

/// The panels of the system a Lister asks with, printing, and what changes its window on the
/// screen: what to open, where to save, the page setup, the print panel, full screen and zoom.
/// The pane uses the system's (`SystemDialogs`); tests put their own in.
@MainActor
internal protocol ViewerDialogs {
    /// A file the user chose to open; nil when cancelled.
    func fileToOpen() -> URL?
    /// Where the user chose to save, `name` proposed; nil when cancelled.
    func saveTarget(proposing name: String) -> URL?
    /// The page setup panel for `info`; whether the user confirmed it.
    func pageLayout(_ info: NSPrintInfo) -> Bool
    /// Runs `operation`: with its panel as a sheet of `window`, or on its own without one.
    func run(_ operation: NSPrintOperation, for window: NSWindow?)
    /// Prints the document of `view` with `info`.
    func print(_ view: PDFView, with info: NSPrintInfo)
    /// Takes `window` to full screen, or back.
    func toggleFullScreen(_ window: NSWindow?)
    /// Makes `window` as large as the screen allows, or back.
    func zoom(_ window: NSWindow?)
}
