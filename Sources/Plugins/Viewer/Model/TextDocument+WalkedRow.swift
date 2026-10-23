import AFMKernel
import Foundation

/// How the rows of a text are cut from a checkpoint on, and how one is drawn.
extension TextDocument {
    /// One row as `walk` hands it on: where it is, and the decoded piece of text it is in.
    internal struct WalkedRow {
        /// The number of the row.
        internal let number: Int
        /// The bytes of the row, line end included.
        internal let bytes: Range<Int64>
        /// Whether the row begins a line (and is not the continuation of a wrapped one).
        internal let startsLine: Bool
        /// The number of the line the row belongs to, counted from 1.
        internal let line: Int
        /// The decoded piece the row is in.
        internal let text: DecodedText
        /// The row's units in `text`.
        internal let units: Range<Int>
        /// The file offset of the first byte of `text`.
        internal let base: Int64

        /// The row as it is drawn: without its line end, tabs expanded to stops `tabWidth` apart,
        /// control characters as spaces.
        internal func displayRow(tabWidth: Int) -> DisplayRow {
            var end = units.upperBound
            if end > units.lowerBound, text.units[end - 1] == 0x0A { end -= 1 }
            if end > units.lowerBound, text.units[end - 1] == 0x0D { end -= 1 }
            let contentEnd = end < units.upperBound ? base + Int64(text.offsets[end]) : bytes.upperBound
            let rowBase = Int32(truncatingIfNeeded: bytes.lowerBound - base)
            var shown: [UInt16] = []
            var offsets: [Int32] = []
            shown.reserveCapacity(end - units.lowerBound)
            offsets.reserveCapacity(end - units.lowerBound)
            var column = 0
            for position in units.lowerBound..<end {
                let unit = text.units[position]
                let offset = text.offsets[position] - rowBase
                if unit == 0x09 {
                    let width = tabWidth - column % tabWidth
                    shown.append(contentsOf: repeatElement(0x20, count: width))
                    offsets.append(contentsOf: repeatElement(offset, count: width))
                    column += width
                } else {
                    // Control characters have no shape; a space keeps the columns.
                    shown.append(unit < 0x20 || (0x7F...0x9F).contains(unit) ? 0x20 : unit)
                    offsets.append(offset)
                    if !(0xDC00...0xDFFF).contains(unit) { column += 1 }
                }
            }
            return DisplayRow(
                index: number,
                range: bytes,
                contentEnd: contentEnd,
                text: String(decoding: shown, as: UTF16.self),
                offsets: offsets,
                startsLine: startsLine,
                line: line
            )
        }
    }

    /// Cuts the text into rows from a checkpoint on and hands each to `visit` until it returns
    /// false.
    internal func walk(
        from position: TextRowIndex.Position,
        _ options: TextLayoutOptions,
        _ cancellation: CancellationFlag?,
        visit: (WalkedRow) -> Bool
    ) throws {
        var splitter = RowSplitter(options)
        splitter.startsLine = position.startsLine
        var row = position.row
        var line = position.linesBefore
        var bytes: [UInt8] = []
        var base = position.offset
        var readPosition = position.offset
        var text = DecodedText()
        var reading = true
        while reading {
            let wanted = Int(min(32 * 1_024, content.upperBound - readPosition))
            let chunk = try source.read(at: readPosition, count: wanted, interruptedBy: cancellation)
            readPosition += Int64(chunk.count)
            bytes.append(contentsOf: chunk)
            // A read inside the file that comes back short: the file has become shorter.
            if chunk.count < wanted { record(ViewerError.fileChanged) }
            let atEnd = chunk.count < wanted || readPosition >= content.upperBound
            let used = encoding.decode(bytes, final: atEnd, into: &text)
            var stop = false
            let consumedUnits = text.units.withUnsafeBufferPointer { units in
                splitter.split(units, final: atEnd) { start, end, startsLine in
                    if startsLine { line += 1 }
                    let lower = base + Int64(text.offsets[start])
                    let upper = base + Int64(end < text.offsets.count ? Int(text.offsets[end]) : used)
                    let walked = WalkedRow(
                        number: row,
                        bytes: lower..<upper,
                        startsLine: startsLine,
                        line: line,
                        text: text,
                        units: start..<end,
                        base: base
                    )
                    stop = !visit(walked)
                    row += 1
                    return !stop
                }
            }
            if stop || atEnd {
                reading = false
            } else {
                let consumed = consumedUnits == text.units.count ? used : Int(text.offsets[consumedUnits])
                bytes.removeFirst(consumed)
                base += Int64(consumed)
            }
        }
    }
}
