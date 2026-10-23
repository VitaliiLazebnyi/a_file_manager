/// Cuts decoded text into rows.
///
/// CR, LF and CR+LF each end a line; a line longer than the allowed width continues in further
/// rows. It works on one piece of text after another: what is left of an unfinished row is handed
/// in again with the next piece. A value without shared state.
internal struct RowSplitter {
    /// Where a run over a piece of text is: the row it is in and the place in it.
    private struct Cursor {
        var rowStart = 0
        var index = 0
        var column = 0
        /// The place after the last space of the row, where a wrapped row may break; -1 for none.
        var lastBreak = -1
        /// Whether the unit before was a zero width joiner: what it joins stays with it.
        var joined = false

        /// Begins the next row at `position`.
        @inline(__always)
        mutating func restart(at position: Int) {
            rowStart = position
            index = position
            column = 0
            lastBreak = -1
            joined = false
        }
    }

    /// How the rows are cut.
    internal let options: TextLayoutOptions
    /// Whether the row at the start of the next piece begins a line (and is not the
    /// continuation of a wrapped one).
    internal var startsLine = true

    /// A splitter for rows cut as `options` say, at the start of a line.
    internal init(_ options: TextLayoutOptions) {
        self.options = options
    }

    /// Units that add no column: combining marks, variation selectors and the zero width spaces
    /// and joiners.
    @inline(__always)
    private static func takesNoColumn(_ unit: UInt16) -> Bool {
        guard unit >= 0x0300 else {
            return false
        }
        switch unit {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x200B...0x200F, 0x20D0...0x20FF, 0x3099...0x309A,
            0xFE00...0xFE0F, 0xFE20...0xFE2F:
            return true

        default:
            return false
        }
    }

    /// Where the line end at `index` (a LF, or a CR when `isCR`) ends, with `next` the unit after
    /// it (nil at the end of the piece): behind a LF, a lone CR or CR+LF.
    ///
    /// Nil for a CR at the end of a piece that is not `final`: whether a LF follows is not known
    /// yet.
    @inline(__always)
    private static func lineEnd(at index: Int, isCR: Bool, next: Int?, final: Bool) -> Int? {
        guard isCR else {
            return index + 1
        }
        guard let next else {
            return final ? index + 1 : nil
        }
        return next == 0x0A ? index + 2 : index + 1
    }

    /// Calls `row` with the unit range of every complete row (line end included) and whether it
    /// begins a line, until `row` returns false.
    ///
    /// Returns the index of the first unit that is not part of a reported row: the start of the
    /// unfinished row to hand in again. With `final`, the text ends here and the last row is
    /// reported too.
    internal mutating func split(
        _ units: UnsafeBufferPointer<UInt16>,
        final: Bool,
        row: (_ start: Int, _ end: Int, _ startsLine: Bool) -> Bool
    ) -> Int {
        runUnits(units, final: final) { start, end, startsLine, _ in row(start, end, startsLine) }
    }

    /// `split`, which also tells how many columns each row takes (its line end not counted).
    internal mutating func splitMeasuring(
        _ units: UnsafeBufferPointer<UInt16>,
        final: Bool,
        row: (_ start: Int, _ end: Int, _ startsLine: Bool, _ width: Int) -> Bool
    ) -> Int {
        runUnits(units, final: final, row: row)
    }

    /// The same for text that is plain ASCII, cut straight from its bytes: no decoding, no
    /// table of offsets (a byte is a unit).
    internal mutating func splitMeasuring(
        _ bytes: UnsafeBufferPointer<UInt8>,
        final: Bool,
        row: (_ start: Int, _ end: Int, _ startsLine: Bool, _ width: Int) -> Bool
    ) -> Int {
        runBytes(bytes, final: final, row: row)
    }

    // The same code twice, for 16-bit units and for bytes: a generic one is slow where nothing is optimised.
    private mutating func runUnits(
        _ units: UnsafeBufferPointer<UInt16>,
        final: Bool,
        row: (Int, Int, Bool, Int) -> Bool
    ) -> Int {
        let count = units.count
        let columns = options.columns
        let tabWidth = options.tabWidth
        // Spaces may hang over the edge instead of opening a row of their own, within reason.
        let hangLimit = columns * 2
        var cursor = Cursor()
        while cursor.index < count {
            let index = cursor.index
            let unit = units[index]
            if unit == 0x0A || unit == 0x0D {
                let next = index + 1 < count ? Int(units[index + 1]) : nil
                guard let end = Self.lineEnd(at: index, isCR: unit == 0x0D, next: next, final: final) else {
                    break
                }
                if !endRow(at: end, &cursor, nextStartsLine: true, row) {
                    return cursor.rowStart
                }
                continue
            }
            let isSpace = unit == 0x20 || unit == 0x09
            // A mark that combines with the character before, the second half of a surrogate
            // pair, and what a joiner joins take no column: a row is never cut in front of them.
            let isSecondHalf = (0xDC00...0xDFFF).contains(unit)
            let takesNone = isSecondHalf || cursor.joined || Self.takesNoColumn(unit)
            let width =
                unit == 0x09
                ? tabWidth - cursor.column % tabWidth
                : takesNone
                    ? 0
                    : unit >= 0x1100 && EastAsianWidth.isWide(units, at: index) ? 2 : 1
            cursor.joined = unit == 0x200D
            // A run of marks with nothing to hold them is cut after a while: a row is never unbounded.
            let endless = takesNone && !isSecondHalf && index - cursor.rowStart >= columns * 4 + 16
            // A unit without width never breaks the row by itself: after a wide character in a row of one column the
            // row is already past its width, and the second half of the character or its mark belongs to it.
            if (width > 0 && cursor.column + width > columns) || endless, index > cursor.rowStart,
                !(isSpace && cursor.column < hangLimit)
            {
                let cut = options.wordWrap && cursor.lastBreak > cursor.rowStart ? cursor.lastBreak : index
                if !endRow(at: cut, &cursor, nextStartsLine: false, row) {
                    return cursor.rowStart
                }
                continue
            }
            cursor.column += width
            cursor.index += 1
            if isSpace { cursor.lastBreak = cursor.index }
        }
        return finishRun(cursor, count: count, final: final, row)
    }

    private mutating func runBytes(
        _ units: UnsafeBufferPointer<UInt8>,
        final: Bool,
        row: (Int, Int, Bool, Int) -> Bool
    ) -> Int {
        let count = units.count
        let columns = options.columns
        let tabWidth = options.tabWidth
        // Spaces may hang over the edge instead of opening a row of their own, within reason.
        let hangLimit = columns * 2
        var cursor = Cursor()
        while cursor.index < count {
            let index = cursor.index
            let unit = units[index]
            if unit == 0x0A || unit == 0x0D {
                let next = index + 1 < count ? Int(units[index + 1]) : nil
                guard let end = Self.lineEnd(at: index, isCR: unit == 0x0D, next: next, final: final) else {
                    break
                }
                if !endRow(at: end, &cursor, nextStartsLine: true, row) {
                    return cursor.rowStart
                }
                continue
            }
            let isSpace = unit == 0x20 || unit == 0x09
            let width = unit == 0x09 ? tabWidth - cursor.column % tabWidth : 1
            if cursor.column + width > columns, index > cursor.rowStart, !(isSpace && cursor.column < hangLimit) {
                let cut = options.wordWrap && cursor.lastBreak > cursor.rowStart ? cursor.lastBreak : index
                if !endRow(at: cut, &cursor, nextStartsLine: false, row) {
                    return cursor.rowStart
                }
                continue
            }
            cursor.column += width
            cursor.index += 1
            if isSpace { cursor.lastBreak = cursor.index }
        }
        return finishRun(cursor, count: count, final: final, row)
    }

    /// Reports the row that ends at `end` and begins the next one there; returns what `row` said
    /// (false: stop).
    @inline(__always)
    private mutating func endRow(
        at end: Int,
        _ cursor: inout Cursor,
        nextStartsLine: Bool,
        _ row: (Int, Int, Bool, Int) -> Bool
    ) -> Bool {
        let goOn = row(cursor.rowStart, end, startsLine, cursor.column)
        startsLine = nextStartsLine
        cursor.restart(at: end)
        return goOn
    }

    /// The end of a run over a piece: with `final`, the unfinished last row is reported too.
    ///
    /// Returns the start of what is left to hand in again.
    @inline(__always)
    private mutating func finishRun(
        _ cursor: Cursor,
        count: Int,
        final: Bool,
        _ row: (Int, Int, Bool, Int) -> Bool
    ) -> Int {
        if final, cursor.rowStart < count, cursor.index == count {
            _ = row(cursor.rowStart, count, startsLine, cursor.column)
            startsLine = false
            return count
        }
        return cursor.rowStart
    }
}
