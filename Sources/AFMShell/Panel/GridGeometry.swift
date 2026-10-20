import CoreGraphics
import Foundation

/// Where the cells of the Brief and Thumbnails views are (spec 03 › Brief, 03 › Thumbnails).
///
/// Cells are numbered like the rows of the panel model. Pure arithmetic: every cell has the same
/// size, so nothing here depends on how many entries the folder has.
internal struct GridGeometry: Equatable {
    /// The order the cells are laid out in.
    internal enum Flow: Equatable {
        /// Brief: the cells fill a column from top to bottom, then the next column to the
        /// right; the list scrolls sideways.
        case columns
        /// Thumbnails: the cells fill a row from left to right, then the next row; the list
        /// scrolls up and down.
        case rows
    }

    /// The arrow key that moves the cursor through the cells.
    internal enum Direction {
        /// ↓.
        case downArrow
        /// ←.
        case leftArrow
        /// →.
        case rightArrow
        /// ↑.
        case upArrow
    }

    /// How the cells are laid out.
    internal let flow: Flow
    /// How many cells there are.
    internal let cellCount: Int
    /// The size of each cell.
    internal let cell: CGSize
    /// The size of the visible part of the list.
    internal let viewport: CGSize

    /// Cells in a column (Brief) or in a row (Thumbnails).
    internal var perLine: Int {
        switch flow {
        case .columns:
            return max(1, Int(viewport.height / max(cell.height, 1)))

        case .rows:
            return max(1, Int(viewport.width / max(cell.width, 1)))
        }
    }

    /// Columns (Brief) or rows (Thumbnails).
    internal var lines: Int { (cellCount + perLine - 1) / perLine }

    /// The size of all the cells together, at least that of the visible part.
    internal var contentSize: CGSize {
        switch flow {
        case .columns:
            return CGSize(width: max(CGFloat(lines) * cell.width, viewport.width), height: viewport.height)

        case .rows:
            return CGSize(width: viewport.width, height: max(CGFloat(lines) * cell.height, viewport.height))
        }
    }

    /// The cells one Page Up or Page Down passes.
    internal var pageSize: Int {
        let visibleLines =
            flow == .columns ? Int(viewport.width / max(cell.width, 1)) : Int(viewport.height / max(cell.height, 1))
        return max(1, max(1, visibleLines) * perLine - (flow == .columns ? 1 : 0))
    }

    /// Where the cell `index` is.
    internal func frame(of index: Int) -> CGRect {
        let (line, offset) = place(of: index)
        switch flow {
        case .columns:
            return CGRect(
                x: CGFloat(line) * cell.width,
                y: CGFloat(offset) * cell.height,
                width: cell.width,
                height: cell.height
            )

        case .rows:
            return CGRect(
                x: CGFloat(offset) * cell.width,
                y: CGFloat(line) * cell.height,
                width: cell.width,
                height: cell.height
            )
        }
    }

    /// The cell at a point; nil on empty space.
    internal func index(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0 else {
            return nil
        }
        let (across, along) = (Int(point.x / cell.width), Int(point.y / cell.height))
        let (line, offset) = flow == .columns ? (across, along) : (along, across)
        guard offset < perLine else {
            return nil
        }
        let index = line * perLine + offset
        return index < cellCount ? index : nil
    }

    /// The cells that may touch a rectangle, for drawing: all cells of the lines it crosses.
    internal func indexes(in rect: CGRect) -> Range<Int> {
        guard cellCount > 0 else {
            return 0..<0
        }
        let (start, end) =
            flow == .columns
            ? (rect.minX / cell.width, rect.maxX / cell.width) : (rect.minY / cell.height, rect.maxY / cell.height)
        // Kept in range before it is a whole number: the visible rectangle of a view in no window
        // reaches to the ends of the floating-point numbers, far past what an Int holds.
        let first = Int(min(max(start.rounded(.down), 0), CGFloat(lines)))
        let last = Int(min(max(end.rounded(.up), CGFloat(first)), CGFloat(lines)))
        return min(first * perLine, cellCount)..<min(last * perLine, cellCount)
    }

    /// Where an arrow key takes the cursor.
    ///
    /// In Brief, ← and → jump a column and stop at the first and the last entry (spec 03 › Brief);
    /// in Thumbnails, ↑ and ↓ jump a row.
    internal func index(from index: Int, moving direction: Direction) -> Int {
        guard cellCount > 0 else {
            return 0
        }
        let step = step(of: direction)
        let target = index + step
        if flow == .rows, abs(step) > 1, !(0..<cellCount).contains(target) {
            // No tile straight above or below: the cursor stays, except on the way down into a
            // last row that is shorter, where it goes to the last tile.
            return step > 0 && place(of: index).line < lines - 1 ? cellCount - 1 : index
        }
        return max(0, min(target, cellCount - 1))
    }

    /// How far an arrow key moves the cursor in the numbering of the cells.
    private func step(of direction: Direction) -> Int {
        switch (flow, direction) {
        case (.columns, .upArrow), (.rows, .leftArrow):
            return -1

        case (.columns, .downArrow), (.rows, .rightArrow):
            return 1

        case (.columns, .leftArrow), (.rows, .upArrow):
            return -perLine

        case (.columns, .rightArrow), (.rows, .downArrow):
            return perLine
        }
    }

    /// The position of a cell: which line it is in, and where in that line.
    private func place(of index: Int) -> (line: Int, offset: Int) {
        (index / perLine, index % perLine)
    }
}
