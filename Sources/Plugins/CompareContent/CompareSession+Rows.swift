/// Rows: what the window draws, row by row, from the content held.
extension CompareSession {
    /// Whether the files are compared byte by byte.
    internal var isBinary: Bool {
        if case .binary = content {
            return true
        }
        return false
    }

    /// How many rows the panes show.
    internal var rowCount: Int {
        switch content {
        case .empty:
            return 0

        case .text(_, _, let diff, _):
            return diff.rows.count

        case .binary(_, _, let diff):
            return diff.rowCount
        }
    }

    /// The differences as ranges of rows.
    internal var blocks: [Range<Int>] {
        switch content {
        case .empty:
            return []

        case .text(_, _, let diff, _):
            return diff.blocks

        case .binary(_, _, let diff):
            return diff.blocks
        }
    }

    /// The length of the longest line in characters, for the width of the panes.
    internal var width: Int {
        switch content {
        case .empty:
            return 0

        case .text(_, _, _, let width):
            return width

        case .binary(_, _, let diff):
            return diff.bytesPerLine * 4 + 1
        }
    }

    /// The difference a row belongs to, found by halving.
    internal func block(containing row: Int) -> Range<Int>? {
        let all = blocks
        var (low, high) = (0, all.count)
        while low < high {
            let middle = (low + high) / 2
            if all[middle].upperBound <= row {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < all.count && all[low].contains(row) ? all[low] : nil
    }

    /// Whether a row is equal on both sides, or what differs; equal for a row outside the content.
    internal func kind(ofRow row: Int) -> DiffRow.Kind {
        switch content {
        case .empty:
            return .equal

        case .text(_, _, let diff, _):
            return diff.rows.indices.contains(row) ? diff.rows[row].kind : .equal

        case .binary:
            return block(containing: row) == nil ? .equal : .changed
        }
    }

    /// The line a row shows on one side; nil where the side has none, or the content is no text.
    private func line(_ side: CompareSide, row: Int) -> TextLine? {
        guard case .text(let left, let right, let diff, _) = content, diff.rows.indices.contains(row) else {
            return nil
        }
        let (document, index) = side == .left ? (left, diff.rows[row].left) : (right, diff.rows[row].right)
        return index.flatMap { found in document.lines.indices.contains(found) ? document.lines[found] : nil }
    }

    /// What stands in front of a row: the line number (0 for a new or changed line), or the
    /// offset in binary mode.
    ///
    /// Empty where the side has no line.
    internal func label(_ side: CompareSide, row: Int) -> String {
        switch content {
        case .empty:
            return ""

        case .text:
            return line(side, row: row).map { found in String(found.number) } ?? ""

        case .binary(let left, let right, let diff):
            return row * diff.bytesPerLine < (side == .left ? left.count : right.count) ? diff.offsetText(row: row) : ""
        }
    }

    /// The text of a row on one side; nil where the side has no line.
    internal func text(_ side: CompareSide, row: Int) -> String? {
        switch content {
        case .empty:
            return nil

        case .text:
            return line(side, row: row)?.text

        case .binary(let left, let right, let diff):
            let text = diff.text(of: side == .left ? left : right, row: row)
            return text.isEmpty ? nil : text
        }
    }

    /// The parts of a row's text that differ from the other side, in UTF-16 units.
    internal func highlights(_ side: CompareSide, row: Int) -> [Range<Int>] {
        switch content {
        case .empty:
            return []

        case .text:
            guard kind(ofRow: row) == .changed, let left = line(.left, row: row), let right = line(.right, row: row)
            else {
                return []
            }
            let ranges: (left: [Range<Int>], right: [Range<Int>])
            if let cached = inlineCache[row] {
                ranges = cached
            } else {
                ranges = TextDiff.inline(left.text, right.text)
                if inlineCache.count >= Self.inlineCacheLimit {
                    inlineCache.removeAll()
                }
                inlineCache[row] = ranges
            }
            return side == .left ? ranges.left : ranges.right

        case .binary(let left, let right, let diff):
            guard kind(ofRow: row) == .changed else {
                return []
            }
            return diff.differingOffsets(left: left, right: right, row: row).flatMap(diff.textRanges)
        }
    }

    /// The first row of the next (or previous) difference as seen from `row`.
    internal func difference(from row: Int, forward: Bool) -> Int? {
        forward
            ? blocks.first { block in block.lowerBound > row }?.lowerBound
            : blocks.last { block in block.lowerBound < row }?.lowerBound
    }
}
