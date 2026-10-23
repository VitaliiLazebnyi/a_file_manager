import AppKit

/// The views of the two panes.
extension CompareWindowController {
    /// The table of one pane, whose keys go to the window first.
    internal final class PaneTableView: NSTableView {
        /// Handles a key; true when it was used, else the table handles it.
        internal var onKey: ((NSEvent) -> Bool)?

        /// Offers the key to `onKey` first.
        override internal func keyDown(with event: NSEvent) {
            if onKey?(event) != true {
                super.keyDown(with: event)
            }
        }
    }

    /// Draws the background that tells what kind of line a row is.
    internal final class DiffRowView: NSTableRowView {
        /// The colour behind the row; nil for none.
        internal var fill: NSColor? { didSet { needsDisplay = true } }

        /// Draws `fill` over the usual background.
        override internal func drawBackground(in dirtyRect: NSRect) {
            super.drawBackground(in: dirtyRect)
            guard let fill else {
                return
            }
            fill.setFill()
            bounds.intersection(dirtyRect).fill(using: .sourceOver)
        }
    }
}
