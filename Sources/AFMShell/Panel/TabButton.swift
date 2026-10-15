import AppKit

/// One tab of a `TabBarView`; its `tag` is its position in the strip.
///
/// It takes the mouse itself, so that a press can turn into a drag to another place in the strip.
internal final class TabButton: NSButton {
    /// The strip the tab is in.
    internal weak var bar: TabBarView?
    /// Where the press under way began, in the window; nil while the button is not pressed.
    private var pressedAt: CGFloat?
    /// The press under way has become a drag.
    private var isDragging = false

    /// A double click closes the tab; a single press waits for the release or a drag.
    override internal func mouseDown(with event: NSEvent) {
        guard event.clickCount != 2 else {
            pressedAt = nil
            bar?.onClose?(tag)
            return
        }
        pressedAt = event.locationInWindow.x
        isDragging = false
    }

    /// The pressed tab is dragged: the strip shows where it would land.
    override internal func mouseDragged(with event: NSEvent) {
        guard let pressedAt else {
            return
        }
        _ = bar?.follow(event, pressing: tag, from: pressedAt, dragging: &isDragging)
    }

    /// The tab is let go: it is shown, or moved where it was dragged.
    override internal func mouseUp(with event: NSEvent) {
        guard let pressedAt else {
            return
        }
        self.pressedAt = nil
        _ = bar?.follow(event, pressing: tag, from: pressedAt, dragging: &isDragging)
    }

    /// A middle click closes the tab.
    override internal func otherMouseDown(with _: NSEvent) {
        bar?.onClose?(tag)
    }

    /// The menu of the tab, from the strip.
    override internal func menu(for _: NSEvent) -> NSMenu? {
        bar?.menuProvider?(tag)
    }

    deinit {
        // Nothing to release.
    }
}
