import AFMKernel
import Foundation

/// A file as rows of text in one encoding and one layout: what a text view pages through.
///
/// It reads only the blocks a request needs. Everything here may block on the file system and is
/// safe to call from several threads; nothing is meant for the main thread except the plain
/// properties and the geometry functions, which touch no file. What changes is guarded by a lock
/// each (`tableLock`, `boundariesLock`, `errorLock`); the rest is immutable.
internal final class TextDocument: @unchecked Sendable {
    /// Where the bytes come from.
    internal let source: any ByteSource
    /// The encoding the rows are decoded in (for the byte layouts, one byte a character).
    internal let encoding: ViewerEncoding
    /// How the bytes are cut into rows.
    internal let layout: ViewerLayout
    /// The bytes that are shown: for text, everything after a byte-order mark.
    internal let content: Range<Int64>
    /// The columns of a hex row of this file.
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

    /// The length of the file.
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
    /// Whether every row is known (always for the byte layouts).
    internal var isIndexComplete: Bool { index?.isComplete ?? true }
    /// How many segments of the index were taken over from the layout this one replaced.
    internal var segmentsReused: Int { index?.segmentsReused ?? 0 }
    /// How many checkpoints the index holds (for tests).
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
        if boundaries == nil {
            boundaries = CharacterBoundaries(
                source: source,
                content: content,
                encoding: encoding,
                spacing: CharacterBoundaries.standardSpacing
            )
        }
        return boundaries
    }

    private let errorLock = NSLock()
    private var fetchFailure: any Error?

    /// The first error that kept a part of the file from being read, if any: what is shown
    /// is then incomplete.
    internal var readError: any Error? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return index?.failure ?? fetchFailure
    }

    /// The text of `source` after a byte-order mark of `bomLength` bytes, in `encoding`, cut as
    /// `layout` says; nothing is read yet.
    ///
    /// `reusing` is a document of the same bytes laid out otherwise (another width): what is
    /// the same in both is not read again.
    internal init(
        source: any ByteSource,
        encoding: ViewerEncoding,
        bomLength: Int,
        layout: ViewerLayout,
        reusing previous: TextDocument?
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
    /// at once. `scanning` says how the text is read (`.standard` in the viewer); `progress` is
    /// called from working threads.
    internal func buildIndex(
        parallel: Bool,
        scanning: TextRowIndex.ScanOptions,
        progress: @escaping @Sendable () -> Void
    ) {
        guard let index, case .text(let options) = layout else {
            return
        }
        index.build(
            TextRowIndex.Input(source: source, content: content, encoding: encoding, options: options),
            parallel: parallel,
            scanning: scanning,
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

    /// Up to `count` rows from row `first` on; fewer at the end of what is known.
    internal func rows(from first: Int, count: Int, cancellation: CancellationFlag?) throws -> [DisplayRow] {
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
            try walk(from: position, options, cancellation) { row in
                if let end = position.endRow, row.number >= end {
                    return false
                }
                guard row.number >= next else {
                    return true
                }
                rows.append(row.displayRow(tabWidth: options.tabWidth))
                return rows.count < wanted
            }
            if rows.count == before { break }
        }
        return rows
    }

    /// The row a byte offset is in; nil while that part of a text is not indexed yet.
    internal func row(containing offset: Int64, cancellation: CancellationFlag?) throws -> Int? {
        guard let index, case .text(let options) = layout else {
            return min(max(0, rowCount - 1), Int(max(0, offset) / Int64(bytesPerRow)))
        }
        let inside = min(max(offset, content.lowerBound), content.upperBound)
        guard let position = index.position(before: inside) else {
            return index.isComplete && index.rowCount == 0 ? 0 : nil
        }
        var found = position.row
        try walk(from: position, options, cancellation) { row in
            if let end = position.endRow, row.number >= end {
                return false
            }
            found = row.number
            return row.bytes.upperBound <= inside
        }
        return min(found, max(0, index.rowCount - 1))
    }

    /// The first row of a line (counted from 1); nil when the line is not known (yet).
    internal func row(ofLine line: Int, cancellation: CancellationFlag?) throws -> Int? {
        guard let index, case .text(let options) = layout else {
            return line >= 1 && line <= rowCount ? line - 1 : nil
        }
        guard let position = index.position(beforeLine: line - 1) else {
            return nil
        }
        var found: Int?
        try walk(from: position, options, cancellation) { row in
            if let end = position.endRow, row.number >= end {
                return false
            }
            if row.startsLine, row.line == line { found = row.number }
            return found == nil && row.line <= line
        }
        return found
    }

    private func fixedRows(from first: Int, count: Int, _ cancellation: CancellationFlag?) throws -> [DisplayRow] {
        let characters = table
        let width = Int64(bytesPerRow)
        let lower = Int64(first) * width
        let upper = min(length, lower + Int64(count) * width)
        let data = [UInt8](try source.read(lower..<upper, cancellation: cancellation))
        if Int64(data.count) < upper - lower { record(ViewerError.fileChanged) }
        let hex = layout == .hex ? hexFormat : nil
        var rows: [DisplayRow] = []
        for position in stride(from: 0, to: data.count, by: Int(width)) {
            let bytes = Array(data[position..<min(data.count, position + Int(width))])
            rows.append(
                .byteRow(first + rows.count, start: lower + Int64(position), bytes: bytes, hex: hex, table: characters)
            )
        }
        return rows
    }

    deinit {
        // Nothing to release.
    }
}
