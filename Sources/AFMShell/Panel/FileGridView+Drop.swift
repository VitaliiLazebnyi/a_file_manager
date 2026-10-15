import AppKit

/// Drag and drop in the Brief and Thumbnails views: the list is the source of the drags that start
/// in it and takes drops on its rows.
extension FileGridView: NSDraggingSource {
    /// What a drag that starts in the list allows, inside the program and outside.
    internal func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext)
        -> NSDragOperation
    {
        [.copy, .move, .generic]
    }

    /// The drag that started here is over, wherever it ended.
    internal func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        PanelDrop.endDrag()
        PanelDrop.endSession(nil)
    }

    /// Starts a drag of `row` (and of the marked items with it, when the row is marked).
    ///
    /// The cell is drawn into an image once; only the first few items carry it (a drag of
    /// thousands of items shows a handful), the others are dragged without a picture. A drag of
    /// very many items is one item on the pasteboard (`PanelDrop.beginDrag`).
    internal func startDrag(ofRow row: Int, for panel: PanelViewController, with event: NSEvent) {
        let frame = geometry.frame(of: row)
        let image = dragImage(ofRow: row)
        let items = panel.draggingItems(forRow: row)
            .enumerated()
            .map { index, pasteboardItem -> NSDraggingItem in
                let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
                dragged.setDraggingFrame(frame, contents: index < Self.imagedDragItems ? image : nil)
                return dragged
            }
        guard !items.isEmpty else {
            return
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        PanelDrop.offerFileNames(on: session.draggingPasteboard)
    }

    /// The cell of `row` as an image, for a drag.
    private func dragImage(ofRow row: Int) -> NSImage {
        let frame = geometry.frame(of: row)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: frame) else {
            return NSImage(size: frame.size)
        }
        cacheDisplay(in: frame, to: bitmap)
        let image = NSImage(size: frame.size)
        image.addRepresentation(bitmap)
        return image
    }
}
