import AppKit

/// A drag session as AppKit hands it to the source of a drag, whose pasteboard is the test's.
internal final class PanelDragSession: NSDraggingSession {
    private let board: NSPasteboard

    /// The pasteboard of the drag.
    override internal var draggingPasteboard: NSPasteboard { board }

    /// A session dragging over `board`.
    internal init(_ board: NSPasteboard) {
        self.board = board
        super.init()
    }
}
