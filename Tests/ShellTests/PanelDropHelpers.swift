import AppKit

@testable import AFMShell

/// What the drop tests make and where they point.
@MainActor
internal enum PanelDropHelpers {
    /// A pasteboard of its own holding `urls`, as Finder writes them.
    internal static func pasteboard(_ urls: [URL]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects(urls.map { $0 as any NSPasteboardWriting })
        return board
    }

    /// The middle of row `row` of the table, in the window.
    internal static func point(ofRow row: Int, in table: NSTableView) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// The middle of cell `row` of the grid, in the window.
    internal static func point(ofRow row: Int, in grid: FileGridView) -> NSPoint {
        let rect = grid.geometry.frame(of: row)
        return grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }
}
