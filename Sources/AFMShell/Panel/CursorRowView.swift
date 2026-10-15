import AppKit

/// A row of the Full view's table.
///
/// It draws the cursor bar, a light bar with a darker border, in the active panel only (spec 03 ›
/// Cursor, selection and row states).
internal final class CursorRowView: NSTableRowView {
    /// What the table knows the row views by, to use them again.
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("afm.row")

    /// The panel the row belongs to.
    internal weak var panel: PanelViewController?

    /// Keeps the text in its own colour on the cursor bar.
    override internal var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// The selected row is the cursor: the bar, while the panel is the source.
    override internal func drawSelection(in _: NSRect) {
        guard panel?.isActive == true else {
            return
        }
        CursorBar.draw(in: bounds)
    }

    deinit {
        // Nothing to release.
    }
}
