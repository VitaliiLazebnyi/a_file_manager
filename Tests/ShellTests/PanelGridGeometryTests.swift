import AFMKernel
import AppKit
import Testing

@testable import AFMShell

/// Where the cells of the Brief and Thumbnails views are, where the arrow keys take the cursor,
/// and how wide a Brief column is (spec 03 › Brief, 03 › Thumbnails).
@MainActor
@Suite
internal struct PanelGridGeometryTests {
    /// Brief fills a column from top to bottom and scrolls sideways; points, rectangles and
    /// pages map to the cells as drawn.
    @Test
    internal func briefFillsColumnsFromTopToBottom() {
        let grid = GridGeometry(
            flow: .columns,
            cellCount: 23,
            cell: CGSize(width: 100, height: 20),
            viewport: CGSize(width: 250, height: 105)
        )
        #expect(grid.perLine == 5 && grid.lines == 5)
        #expect(grid.contentSize == CGSize(width: 500, height: 105))
        #expect(grid.frame(of: 0) == CGRect(x: 0, y: 0, width: 100, height: 20))
        #expect(grid.frame(of: 7) == CGRect(x: 100, y: 40, width: 100, height: 20))
        #expect(grid.index(at: CGPoint(x: 150, y: 45)) == 7)
        // Below the last full row of a column, and behind the last entry, is empty space.
        #expect(grid.index(at: CGPoint(x: 150, y: 102)) == nil && grid.index(at: CGPoint(x: 450, y: 70)) == nil)
        #expect(grid.index(at: CGPoint(x: 450, y: 45)) == 22 && grid.index(at: CGPoint(x: -1, y: 5)) == nil)
        #expect(grid.indexes(in: CGRect(x: 120, y: 0, width: 100, height: 105)) == 5..<15)
        #expect(grid.indexes(in: CGRect(x: 420, y: 0, width: 500, height: 105)) == 20..<23)
        // The visible rectangle of a view in no window: every cell.
        #expect(grid.indexes(in: .infinite) == 0..<23)
        #expect(grid.pageSize == 9)
    }

    /// In Brief ↑ and ↓ step a row and ← and → a column, stopping at the first and the last entry.
    @Test
    internal func arrowKeysInBrief() {
        let grid = GridGeometry(
            flow: .columns,
            cellCount: 23,
            cell: CGSize(width: 100, height: 20),
            viewport: CGSize(width: 250, height: 100)
        )
        #expect(grid.index(from: 7, moving: .downArrow) == 8 && grid.index(from: 7, moving: .upArrow) == 6)
        #expect(grid.index(from: 7, moving: .rightArrow) == 12 && grid.index(from: 7, moving: .leftArrow) == 2)
        // ← in the first column and → in the last go to the first and the last entry.
        #expect(grid.index(from: 3, moving: .leftArrow) == 0 && grid.index(from: 19, moving: .rightArrow) == 22)
        #expect(grid.index(from: 22, moving: .downArrow) == 22 && grid.index(from: 0, moving: .upArrow) == 0)
    }

    /// Thumbnails fill a row from left to right and scroll up and down; ↑ and ↓ jump a row.
    @Test
    internal func thumbnailsFillRowsAndScrollVertically() {
        let grid = GridGeometry(
            flow: .rows,
            cellCount: 10,
            cell: CGSize(width: 100, height: 120),
            viewport: CGSize(width: 450, height: 200)
        )
        #expect(grid.perLine == 4 && grid.lines == 3 && grid.contentSize == CGSize(width: 450, height: 360))
        #expect(grid.frame(of: 5) == CGRect(x: 100, y: 120, width: 100, height: 120))
        #expect(grid.index(at: CGPoint(x: 150, y: 130)) == 5 && grid.index(at: CGPoint(x: 420, y: 10)) == nil)
        #expect(grid.index(at: CGPoint(x: 250, y: 250)) == nil)
        #expect(grid.indexes(in: CGRect(x: 0, y: 100, width: 450, height: 50)) == 0..<8)
        #expect(grid.index(from: 5, moving: .rightArrow) == 6 && grid.index(from: 5, moving: .leftArrow) == 4)
        #expect(grid.index(from: 5, moving: .upArrow) == 1 && grid.index(from: 5, moving: .downArrow) == 9)
        // No tile straight below in the shorter last row: the last tile; none above the first row: stay.
        #expect(grid.index(from: 7, moving: .downArrow) == 9 && grid.index(from: 9, moving: .downArrow) == 9)
        #expect(grid.index(from: 2, moving: .upArrow) == 2)
        #expect(grid.pageSize == 4)
    }

    /// A grid without entries or without room still answers.
    @Test
    internal func anEmptyOrTinyGridDoesNotBreak() {
        let empty = GridGeometry(flow: .columns, cellCount: 0, cell: CGSize(width: 100, height: 20), viewport: .zero)
        #expect(empty.perLine == 1 && empty.lines == 0)
        #expect(empty.indexes(in: CGRect(x: 0, y: 0, width: 50, height: 50)).isEmpty)
        #expect(empty.index(from: 0, moving: .rightArrow) == 0 && empty.index(at: .zero) == nil && empty.pageSize == 1)
    }

    /// A Brief column is as wide as the longest name, up to the limit and the panel's width.
    @Test
    internal func aBriefColumnIsAsWideAsTheLongestNameUpToTheLimit() {
        func width(_ names: [String], limit: CGFloat?) -> CGFloat {
            let items = names.map { FileItem(url: URL(fileURLWithPath: "/x/" + $0), name: $0) }
            let widest = GridCellPainter.widestBriefName(in: items)
            return GridCellPainter.briefColumnWidth(widest: widest, limit: limit, viewport: 600)
        }
        let short = ["a.txt", "bb.txt"]
        let long = short + [String(repeating: "w", count: 120) + ".txt"]
        #expect(width(short, limit: 200) == 80)
        #expect(width(long, limit: 200) == 200)
        // Without a limit the panel's width is the limit; without a panel width, the limit alone.
        #expect(width(long, limit: nil) == 600)
        #expect(GridCellPainter.briefColumnWidth(widest: 1_000, limit: nil, viewport: 0) == 1_036)
        let medium = width(short + ["a-name-of-middling-length.txt"], limit: 400)
        #expect(medium > 150 && medium < 300)
        #expect(width([], limit: 200) == 80)
        // Only the longest names are measured; among many, the longest still decides.
        let many = (0..<20).map { "name\($0).txt" } + [String(repeating: "m", count: 40)]
        #expect(width(many, limit: 400) == width([String(repeating: "m", count: 40)], limit: 400))
    }
}
