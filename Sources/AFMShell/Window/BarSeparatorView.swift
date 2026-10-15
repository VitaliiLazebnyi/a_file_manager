import AppKit

/// The line in front of a group of the button bar.
///
/// It separates the group from the one before it and is the handle by which the group is
/// dragged. Main thread only.
internal final class BarSeparatorView: NSView {
    /// The width of the handle.
    internal static let width: CGFloat = 9
    /// Takes a press on the handle; nil leaves it to the view.
    internal var onMouseDown: ((NSEvent) -> Void)?

    /// A thin vertical line in the middle.
    override internal func draw(_: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: floor(bounds.midX), y: 3, width: 1, height: max(bounds.height - 6, 0)).fill()
    }

    /// A press goes to whoever drags the group.
    override internal func mouseDown(with event: NSEvent) {
        guard let onMouseDown else {
            super.mouseDown(with: event)
            return
        }
        onMouseDown(event)
    }

    /// An open hand over a handle that can be dragged.
    override internal func resetCursorRects() {
        if onMouseDown != nil {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
