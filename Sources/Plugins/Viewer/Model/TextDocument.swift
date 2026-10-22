import AFMKernel
import Foundation

/// The three ways bytes are laid out in rows (spec 10 › Display modes 1–3; Unicode and UTF-8
/// are text in another encoding).
internal enum ViewerLayout: Equatable {
    case text(TextLayoutOptions)
    /// A continuous stream of characters cut into rows of a fixed number of bytes.
    case binary(width: Int)
    /// Offset, sixteen bytes in hex, the same bytes as characters.
    case hex
}

/// One row as it is drawn, with what is needed to find a place in it in the file again.
internal struct DisplayRow {
    internal let index: Int
    /// The bytes of the row, line end included.
    internal let range: Range<Int64>
    /// Where the line end begins (the end of the row when it has none).
    internal let contentEnd: Int64
    /// What is drawn: no line end, tabs expanded, control characters replaced.
    internal let text: String
    /// For each UTF-16 unit of `text`, its byte offset from the start of the row.
    ///
    /// Empty for hex rows, whose columns are fixed (`HexFormat`).
    internal let offsets: [Int32]
    internal let startsLine: Bool
    /// The number of the line the row belongs to, counted from 1.
    internal let line: Int
}

/// The hex display of the specification (10 › Hex):
/// `00000000: 52 65 70 6F 72 74 20 31|0D 0A 4C 6F 72 65 6D 20 | Report 1..Lorem `.
internal struct HexFormat: Equatable {
    internal static let bytesPerRow = 16
    /// Eight digits as in the specification; more for files they cannot address.
    internal let offsetDigits: Int

    internal init(length: Int64) {
        offsetDigits = max(8, String(max(0, length - 1), radix: 16).count)
    }

    /// Control characters and bytes without a character show as a dot (spec 10 › Binary, Hex).
    internal static func printable(_ unit: UInt16) -> UInt16 {
        unit < 0x20 || (0x7F...0x9F).contains(unit) || unit == CodeTable.leadByte || unit == CodeTable.replacement
            ? 0x2E : unit
    }

    /// Bytes as hexadecimal text for the clipboard: `52 65 70 6F`.
    internal static func hexString(_ data: Data) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(data.count * 3)
        for byte in data {
            if !text.isEmpty { text.append(0x20) }
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// The column of the first hex digit of byte `position` in a row.
    internal func hexColumn(_ position: Int) -> Int { offsetDigits + 2 + position * 3 }
    /// The column of the character of byte `position`.
    internal func characterColumn(_ position: Int) -> Int { offsetDigits + 2 + Self.bytesPerRow * 3 + 2 + position }

    internal func line(offset: Int64, bytes: [UInt8], table: CodeTable) -> String {
        let digits = Array("0123456789ABCDEF".utf16)
        var units: [UInt16] = []
        units.reserveCapacity(characterColumn(Self.bytesPerRow))
        let offsetText = String(offset, radix: 16, uppercase: true)
        units.append(contentsOf: repeatElement(0x30, count: max(0, offsetDigits - offsetText.count)))
        units.append(contentsOf: offsetText.utf16)
        units.append(contentsOf: [0x3A, 0x20])
        for position in 0..<Self.bytesPerRow {
            if position < bytes.count {
                units.append(digits[Int(bytes[position] >> 4)])
                units.append(digits[Int(bytes[position] & 0x0F)])
                units.append(position == 7 && bytes.count > 8 ? 0x7C : 0x20)
            } else {
                units.append(contentsOf: [0x20, 0x20, 0x20])
            }
        }
        units.append(contentsOf: [0x7C, 0x20])
        for byte in bytes { units.append(Self.printable(table.single[Int(byte)])) }
        return String(decoding: units, as: UTF16.self)
    }
}

/// A file as rows of text in one encoding and one layout: what a text view pages through.
///
/// It reads only the blocks a request needs. Everything here may block on the file system and is
/// safe to call from several threads; nothing is meant for the main thread except the plain
/// properties and the geometry functions, which touch no file. What changes is guarded by a lock
/// each (`tableLock`, `boundariesLock`, `errorLock`); the rest is immutable.
internal final class TextDocument: @unchecked Sendable {
    internal let source: any ByteSource
    internal let encoding: ViewerEncoding
    internal let layout: ViewerLayout
    /// The bytes that are shown: for text, everything after a byte-order mark.
    internal let content: Range<Int64>
    internal let hexFormat: HexFormat
    /// Stops everything the document is doing (indexing, reading rows); set by whoever drops it.
    internal let cancellation: CancellationFlag
    /// Stops the indexing alone, which ends with `cancellation` too: rows can still be read.
    private let indexStop: LinkedCancellation
    private let index: TextRowIndex?
    /// The encoding of the byte layouts' characters.
    private let tableEncoding: ViewerEncoding
    private let tableLock = NSLock()
    private var builtTable: CodeTable?

    /// The conversion table of the byte layouts, made when rows are first read (a table of a
    /// double-byte code page takes a moment): not on the main thread.
    private var table: CodeTable {
        tableLock.lock()
        defer { tableLock.unlock() }
        let made = builtTable ?? CodeTable.table(for: tableEncoding)
        builtTable = made
        return made
    }

    internal var length: Int64 { source.length }

    private var bytesPerRow: Int {
        switch layout {
        case .binary(let width):
            return max(1, width)

        default:
            return HexFormat.bytesPerRow
        }
    }

    /// The rows known so far; for text it grows while the index is being built.
    internal var rowCount: Int {
        if let index {
            return index.rowCount
        }
        // (The length is what a file system says, and a server may say anything: the sum must not overflow.)
        return Int(max(0, length).addingSaturated(Int64(bytesPerRow) - 1) / Int64(bytesPerRow))
    }

    /// Lines of text known so far; for the byte layouts every row is a line.
    internal var lineCount: Int { index?.lineCount ?? rowCount }
    internal var isIndexComplete: Bool { index?.isComplete ?? true }
    /// How many segments of the index were taken over from the layout this one replaced.
    internal var segmentsReused: Int { index?.segmentsReused ?? 0 }
    internal var checkpointCount: Int { index?.checkpointCount ?? 0 }
    /// The rows of everything before this offset are known.
    internal var indexedThrough: Int64 { index.map { $0.isComplete ? length : $0.indexedThrough } ?? length }

    /// The flag that ends the building of the index (the document's own ends it too).
    internal var indexCancellation: CancellationFlag { indexStop.flag }

    private let boundariesLock = NSLock()
    private var boundaries: CharacterBoundaries?

    /// What a search cuts a text in a double-byte code page into characters with; nil for any
    /// other.
    ///
    /// Kept for as long as the document is, so the next search finds the boundaries of the last
    /// one.
    internal var characterBoundaries: CharacterBoundaries? {
        guard encoding.kind == .doubleByte else {
            return nil
        }
        boundariesLock.lock()
        defer { boundariesLock.unlock() }
        if boundaries == nil { boundaries = CharacterBoundaries(source: source, content: content, encoding: encoding) }
        return boundaries
    }

    // MARK: Read errors

    private let errorLock = NSLock()
    private var fetchFailure: any Error?

    /// The first error that kept a part of the file from being read, if any: what is shown
    /// is then incomplete.
    internal var readError: any Error? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return index?.failure ?? fetchFailure
    }

    /// `reusing` is a document of the same bytes laid out otherwise (another width): what is
    /// the same in both is not read again.
    internal init(
        source: any ByteSource,
        encoding: ViewerEncoding,
        bomLength: Int = 0,
        layout: ViewerLayout,
        reusing previous: TextDocument? = nil
    ) {
        self.source = source
        self.layout = layout
        let flag = CancellationFlag()
        cancellation = flag
        indexStop = LinkedCancellation(flag)
        hexFormat = HexFormat(length: source.length)
        tableEncoding = encoding.byteOriented
        switch layout {
        case .text:
            self.encoding = encoding
            let range = min(Int64(bomLength), source.length)..<source.length
            content = range
            let before =
                previous?.source === source && previous?.encoding == encoding && previous?.content == range
                ? previous?.index : nil
            index = TextRowIndex(start: range.lowerBound, reusing: before)

        case .binary, .hex:
            self.encoding = encoding.byteOriented
            content = 0..<source.length
            index = nil
        }
    }

    /// Finds the rows of a text.
    ///
    /// Blocks until done or cancelled (`cancellation`); the byte layouts need no index and return
    /// at once. `progress` is called from working threads.
    internal func buildIndex(
        parallel: Bool,
        segmentSize: Int = 4 << 20,
        chunkSize: Int = 1 << 20,
        rawScan: Bool = true,
        progress: @escaping @Sendable () -> Void = {}
    ) {
        guard let index, case .text(let options) = layout else {
            return
        }
        index.build(
            source: source,
            content: content,
            encoding: encoding,
            options: options,
            parallel: parallel,
            segmentSize: segmentSize,
            chunkSize: chunkSize,
            rawScan: rawScan,
            cancellation: indexStop.flag,
            progress: progress
        )
    }

    /// Stops building the index (a newer layout of the same text takes over); what was found
    /// stays, and rows can be read as before.
    internal func stopIndexing() {
        indexStop.flag.cancel()
    }

    /// Keeps the first error met while reading rows (the index keeps its own).
    internal func record(_ error: any Error) {
        errorLock.lock()
        if fetchFailure == nil { fetchFailure = error }
        errorLock.unlock()
    }

    // MARK: Rows

    /// Up to `count` rows from row `first` on; fewer at the end of what is known.
    internal func rows(from first: Int, count: Int, cancellation: CancellationFlag? = nil) throws -> [DisplayRow] {
        let available = rowCount
        guard first >= 0, first < available, count > 0 else {
            return []
        }
        let wanted = min(count, available - first)
        guard let index, case .text(let options) = layout else {
            return try fixedRows(from: first, count: wanted, cancellation)
        }
        var rows: [DisplayRow] = []
        rows.reserveCapacity(wanted)
        // A part of the file that could not be read leaves a gap in the rows: they go on at the
        // checkpoint of the next row that is known, never with the text read through the gap.
        // A row the index no longer knows (the partial state of a segment that failed was dropped) ends them.
        while rows.count < wanted, let position = index.position(ofRow: first + rows.count) {
            let next = first + rows.count
            let before = rows.count
            try walk(from: position, options, cancellation) { row, bytes, startsLine, line, text, units, base in
                if let end = position.endRow, row >= end {
                    return false
                }
                guard row >= next else {
                    return true
                }
                rows.append(makeRow(options, row, bytes, startsLine, line, text, units, base))
                return rows.count < wanted
            }
            if rows.count == before { break }
        }
        return rows
    }

    /// The row a byte offset is in; nil while that part of a text is not indexed yet.
    internal func row(containing offset: Int64, cancellation: CancellationFlag? = nil) throws -> Int? {
        guard let index, case .text(let options) = layout else {
            return min(max(0, rowCount - 1), Int(max(0, offset) / Int64(bytesPerRow)))
        }
        let offset = min(max(offset, content.lowerBound), content.upperBound)
        guard let position = index.position(before: offset) else {
            return index.isComplete && index.rowCount == 0 ? 0 : nil
        }
        var found = position.row
        try walk(from: position, options, cancellation) { row, bytes, _, _, _, _, _ in
            if let end = position.endRow, row >= end {
                return false
            }
            found = row
            return bytes.upperBound <= offset
        }
        return min(found, max(0, index.rowCount - 1))
    }

    /// The first row of a line (counted from 1); nil when the line is not known (yet).
    internal func row(ofLine line: Int, cancellation: CancellationFlag? = nil) throws -> Int? {
        guard let index, case .text(let options) = layout else {
            return line >= 1 && line <= rowCount ? line - 1 : nil
        }
        guard let position = index.position(beforeLine: line - 1) else {
            return nil
        }
        var found: Int?
        try walk(from: position, options, cancellation) { row, _, startsLine, number, _, _, _ in
            if let end = position.endRow, row >= end {
                return false
            }
            if startsLine, number == line { found = row }
            return found == nil && number <= line
        }
        return found
    }

    /// Cuts the text into rows from a checkpoint on and hands each to `visit` until it returns
    /// false: the row's number, its bytes, whether it begins a line, the number of its line,
    /// and the decoded piece it is in with its unit range and the byte offset of that piece.
    private func walk(
        from position: TextRowIndex.Position,
        _ options: TextLayoutOptions,
        _ cancellation: CancellationFlag?,
        visit: (Int, Range<Int64>, Bool, Int, DecodedText, Range<Int>, Int64) -> Bool
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
                    stop = !visit(row, lower..<upper, startsLine, line, text, start..<end, base)
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

    private func makeRow(
        _ options: TextLayoutOptions,
        _ row: Int,
        _ bytes: Range<Int64>,
        _ startsLine: Bool,
        _ line: Int,
        _ text: DecodedText,
        _ units: Range<Int>,
        _ base: Int64
    ) -> DisplayRow {
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
                let width = options.tabWidth - column % options.tabWidth
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
            index: row,
            range: bytes,
            contentEnd: contentEnd,
            text: String(decoding: shown, as: UTF16.self),
            offsets: offsets,
            startsLine: startsLine,
            line: line
        )
    }

    private func fixedRows(from first: Int, count: Int, _ cancellation: CancellationFlag?) throws -> [DisplayRow] {
        let characters = table
        let width = Int64(bytesPerRow)
        let lower = Int64(first) * width
        let upper = min(length, lower + Int64(count) * width)
        let data = [UInt8](try source.read(lower..<upper, cancellation: cancellation))
        if Int64(data.count) < upper - lower { record(ViewerError.fileChanged) }
        var rows: [DisplayRow] = []
        var position = 0
        while position < data.count {
            let bytes = Array(data[position..<min(data.count, position + Int(width))])
            let start = lower + Int64(position)
            let range = start..<start + Int64(bytes.count)
            let number = first + rows.count
            if layout == .hex {
                rows.append(
                    DisplayRow(
                        index: number,
                        range: range,
                        contentEnd: range.upperBound,
                        text: hexFormat.line(offset: start, bytes: bytes, table: characters),
                        offsets: [],
                        startsLine: true,
                        line: number + 1
                    )
                )
            } else {
                let units = bytes.map { HexFormat.printable(characters.single[Int($0)]) }
                rows.append(
                    DisplayRow(
                        index: number,
                        range: range,
                        contentEnd: range.upperBound,
                        text: String(decoding: units, as: UTF16.self),
                        offsets: bytes.indices.map(Int32.init),
                        startsLine: true,
                        line: number + 1
                    )
                )
            }
            position += Int(width)
        }
        return rows
    }

    // MARK: Geometry (no file access)

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
        let from = textIndex(in: row, of: lower)
        let to = textIndex(in: row, of: upper)
        return from < to ? [from..<to] : []
    }

    // MARK: Copying

    /// The bytes of `range` as text for the clipboard, in the document's encoding; NUL becomes
    /// a space (spec 10 › Selection and clipboard).
    ///
    /// Blocks.
    internal func text(in range: Range<Int64>, cancellation: CancellationFlag? = nil) throws -> String {
        var text = DecodedText()
        text.tracksOffsets = false
        encoding.decode(try source.read(range, cancellation: cancellation), final: true, into: &text)
        for index in text.units.indices where text.units[index] == 0 { text.units[index] = 0x20 }
        return text.string
    }
}
