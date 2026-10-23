import Foundation

/// Where the bytes of a row are in its text, and the other way round; no file access.
extension TextDocument {
    /// The byte offset of the place before UTF-16 unit `textIndex` of a row's text.
    internal func byteOffset(in row: DisplayRow, at textIndex: Int) -> Int64 {
        if layout == .hex {
            let count = Int(row.range.upperBound - row.range.lowerBound)
            let position =
                textIndex >= hexFormat.characterColumn(0)
                ? textIndex - hexFormat.characterColumn(0)
                : (textIndex - hexFormat.hexColumn(0) + 1) / 3
            return row.range.lowerBound + Int64(min(max(position, 0), count))
        }
        guard textIndex < row.offsets.count else {
            return row.contentEnd
        }
        return row.range.lowerBound + Int64(row.offsets[max(0, textIndex)])
    }

    /// The UTF-16 index in a row's text of the character at a byte offset (the text's length
    /// when the offset is behind the row's text).
    ///
    /// In hex rows, the place in the hex part.
    internal func textIndex(in row: DisplayRow, of offset: Int64) -> Int {
        if layout == .hex {
            return hexFormat.hexColumn(
                Int(min(max(offset, row.range.lowerBound), row.range.upperBound) - row.range.lowerBound)
            )
        }
        let relative = offset - row.range.lowerBound
        var low = 0
        var high = row.offsets.count
        while low < high {
            let middle = (low + high) / 2
            if Int64(row.offsets[middle]) < relative { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The parts of a row's text that show bytes of `selection`.
    ///
    /// A hex row shows them twice: in the hex part and in the character part (spec 10 › Hex).
    internal func textRanges(in row: DisplayRow, for selection: Range<Int64>) -> [Range<Int>] {
        let lower = max(selection.lowerBound, row.range.lowerBound)
        let upper = min(selection.upperBound, row.range.upperBound)
        guard lower < upper else {
            return []
        }
        if layout == .hex {
            let first = Int(lower - row.range.lowerBound)
            let last = Int(upper - row.range.lowerBound)
            return [
                hexFormat.hexColumn(first)..<hexFormat.hexColumn(last - 1) + 2,
                hexFormat.characterColumn(first)..<hexFormat.characterColumn(last)
            ]
        }
        let lowerIndex = textIndex(in: row, of: lower)
        let upperIndex = textIndex(in: row, of: upper)
        return lowerIndex < upperIndex ? [lowerIndex..<upperIndex] : []
    }
}
