import AppKit

/// The in-place name editor in the Brief and Thumbnails views.
extension FileGridView {
    /// Where the name of a row is drawn, for the in-place name editor.
    internal func nameFrame(ofRow row: Int) -> NSRect {
        let frame = geometry.frame(of: row)
        switch flow {
        case .columns:
            return NSRect(x: frame.minX + 22, y: frame.minY, width: frame.width - 24, height: frame.height)

        case .rows:
            return NSRect(x: frame.minX + 2, y: frame.maxY - 36, width: frame.width - 4, height: 20)
        }
    }
}
