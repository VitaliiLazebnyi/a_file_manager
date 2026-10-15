import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// The rows of a document: the byte layouts, long lines, gaps in the index, and texts that
/// changed after they were indexed.
@Suite
internal struct CoverageViewerDocumentTests {
    private static let wrapped = ViewerLayout.text(TextLayoutOptions(columns: 80, wordWrap: true))

    // MARK: Documents

    /// The byte layouts have every row a line, need no index and find rows by arithmetic.
    @Test
    internal func theByteLayoutsCountRowsByArithmetic() throws {
        let document = TextDocument(source: DataByteSource(Data(count: 100)), encoding: .utf8, layout: .hex)
        #expect(document.rowCount == 7 && document.lineCount == 7 && document.isIndexComplete)
        #expect(document.segmentsReused == 0 && document.checkpointCount == 0 && document.indexedThrough == 100)
        #expect(try document.row(containing: 40) == 2)
        #expect(try document.row(ofLine: 3) == 2 && document.row(ofLine: 0) == nil && document.row(ofLine: 8) == nil)
        #expect(document.characterBoundaries == nil)
    }

    /// A text in a code page of more than one byte keeps one set of boundaries for its searches.
    @Test
    internal func aDoubleByteTextKeepsItsBoundaries() throws {
        let encoding = try #require(ViewerEncoding.codePage(936))
        let document = TextDocument(source: DataByteSource(Data("abc".utf8)), encoding: encoding, layout: Self.wrapped)
        let first = try #require(document.characterBoundaries)
        #expect(document.characterBoundaries === first)
    }

    /// Stopping the index, or the document, ends the index's flag.
    @Test
    internal func theIndexFlagEndsWithTheDocument() {
        let document = TextDocument(source: DataByteSource(Data("a".utf8)), encoding: .utf8, layout: Self.wrapped)
        #expect(!document.indexCancellation.isCancelled)
        document.stopIndexing()
        #expect(document.indexCancellation.isCancelled && !document.cancellation.isCancelled)
        let other = TextDocument(source: DataByteSource(Data("a".utf8)), encoding: .utf8, layout: Self.wrapped)
        other.cancellation.cancel()
        #expect(other.indexCancellation.isCancelled)
    }

    /// A line longer than one piece of reading is read on until its rows are found; the last
    /// row of a text without a final line end ends with the text.
    @Test
    internal func longLinesAreReadInSeveralPieces() throws {
        let long = String(repeating: "a", count: 100_000)
        let data = Data((long + "\nb").utf8)
        let layout = ViewerLayout.text(TextLayoutOptions(columns: 200_000, wordWrap: false))
        let document = TextDocument(source: DataByteSource(data), encoding: .utf8, layout: layout)
        document.buildIndex(parallel: false)
        let rows = try document.rows(from: 0, count: 2)
        #expect(rows.count == 2)
        #expect(rows[0].range == 0..<100_001 && rows[0].text.count == 100_000)
        #expect(rows[1].range == 100_001..<100_002 && rows[1].text == "b")
        // A line that ends exactly where a piece of reading ends.
        let exact = Data((String(repeating: "c", count: 32 * 1_024 - 1) + "\nd\n").utf8)
        let second = TextDocument(source: DataByteSource(exact), encoding: .utf8, layout: layout)
        second.buildIndex(parallel: false)
        #expect(try second.rows(from: 1, count: 1).first?.text == "d")
    }

    /// The line end of a row shows no text: a selection of it alone marks nothing.
    @Test
    internal func aSelectedLineEndMarksNoText() throws {
        let document = TextDocument(
            source: DataByteSource(Data("ab\r\ncd".utf8)),
            encoding: .utf8,
            layout: Self.wrapped
        )
        document.buildIndex(parallel: false)
        let row = try #require(try document.rows(from: 0, count: 1).first)
        #expect(document.textRanges(in: row, for: 2..<4).isEmpty)
        #expect(document.textRanges(in: row, for: 1..<4) == [1..<2])
    }

    /// A text that became shorter after it was indexed gives no rows where its bytes are gone,
    /// and says so.
    @Test
    internal func rowsOfBytesThatAreGoneAreNotMadeUp() throws {
        let source = CoverageViewerChangingSource(Data("one\ntwo\nthree\n".utf8))
        let document = TextDocument(source: source, encoding: .utf8, layout: Self.wrapped)
        document.buildIndex(parallel: false)
        #expect(document.rowCount == 3)
        source.replace(with: Data())
        #expect(try document.rows(from: 1, count: 2).isEmpty)
        #expect(document.readError as? ViewerError == .fileChanged)
    }

    /// A text that is gone before it is indexed has no rows, and the index says why.
    @Test
    internal func aTextThatIsGoneHasNoRows() {
        let document = TextDocument(
            source: CoverageViewerShortSource(length: 100, available: 0),
            encoding: .utf8,
            layout: Self.wrapped
        )
        document.buildIndex(parallel: false)
        #expect(document.isIndexComplete && document.rowCount == 0)
        #expect(document.readError as? ViewerError == .fileChanged)
    }

    /// Rows after a part that could not be indexed are not walked into from before it: the rows
    /// and lines of the part before end where it ends.
    @Test
    internal func aGapInTheIndexIsNotWalkedThrough() throws {
        let line = Data("abcdefghi\n".utf8)
        let text = Data((0..<3_000).flatMap { _ in line })
        let source = CoverageViewerChangingSource(text)
        // The second segment (bytes 1000 to 2000) cannot be read while the index is built.
        source.fail(1_100..<2_000)
        let document = TextDocument(source: source, encoding: .utf8, layout: Self.wrapped)
        document.buildIndex(parallel: false, segmentSize: 1_000, chunkSize: 100)
        source.fail(nil)
        #expect(document.isIndexComplete && document.readError != nil)
        // An offset in the gap belongs to the last row before it.
        #expect(try document.row(containing: 1_500) == 100)
        // With other bytes, the lines are not found in the rows before the gap.
        source.replace(with: Data(repeating: 0x78, count: text.count))
        #expect(try document.row(ofLine: 100) == nil)
    }

    /// An empty text has its one place in row 0.
    @Test
    internal func anEmptyTextIsRowZero() throws {
        let document = TextDocument(source: DataByteSource(Data()), encoding: .utf8, layout: Self.wrapped)
        document.buildIndex(parallel: false)
        #expect(try document.row(containing: 0) == 0)
    }

    /// The index knows no place for a row it has not found.
    @Test
    internal func anUnknownRowHasNoPlace() {
        let index = TextRowIndex()
        let options = TextLayoutOptions(columns: 80, wordWrap: true)
        index.build(
            source: DataByteSource(Data("a\nb\n".utf8)),
            content: 0..<4,
            encoding: .utf8,
            options: options,
            parallel: false,
            cancellation: CancellationFlag()
        ) {
            // No progress to show.
        }
        #expect(index.rowCount == 2 && index.position(ofRow: 1) != nil)
        #expect(index.position(ofRow: 2) == nil && index.position(ofRow: -1) == nil)
    }

    /// Nothing is known before the first part of a text that could be indexed.
    @Test
    internal func nothingIsKnownBeforeTheFirstIndexedPart() throws {
        let line = Data("abcdefghi\n".utf8)
        let source = CoverageViewerChangingSource(Data((0..<300).flatMap { _ in line }))
        source.fail(0..<1_000)
        let document = TextDocument(source: source, encoding: .utf8, layout: Self.wrapped)
        document.buildIndex(parallel: true, segmentSize: 1_000, chunkSize: 100)
        source.fail(nil)
        #expect(document.isIndexComplete && document.rowCount > 0)
        #expect(try document.row(containing: 500) == nil)
    }

    // MARK: Rows

    /// A CR at the end of a piece waits for the next: a LF may follow.
    @Test
    internal func aCarriageReturnAtTheEndOfAPieceWaits() {
        var splitter = RowSplitter(TextLayoutOptions(columns: 80, wordWrap: true))
        let units = Array("ab\r".utf16)
        var rows: [Range<Int>] = []
        let used = units.withUnsafeBufferPointer { buffer in
            splitter.split(buffer, final: false) { start, end, _ in
                rows.append(start..<end)
                return true
            }
        }
        #expect(used == 0 && rows.isEmpty)
        let last = units.withUnsafeBufferPointer { buffer in
            splitter.split(buffer, final: true) { start, end, _ in
                rows.append(start..<end)
                return true
            }
        }
        #expect(last == 3 && rows == [0..<3])
        // The same for text cut from its bytes.
        var byteSplitter = RowSplitter(TextLayoutOptions(columns: 80, wordWrap: true))
        let bytes = Array("ab\r".utf8)
        var measured: [Int] = []
        let usedBytes = bytes.withUnsafeBufferPointer { buffer in
            byteSplitter.splitMeasuring(buffer, final: false) { _, end, _, _ in
                measured.append(end)
                return true
            }
        }
        #expect(usedBytes == 0 && measured.isEmpty)
    }

    /// Half a surrogate pair is no wide character.
    @Test
    internal func halfASurrogatePairIsNotWide() {
        let alone: [UInt16] = [0xD840]
        let unpaired: [UInt16] = [0xD840, 0x41]
        let pair = Array("\u{20000}".utf16)
        #expect(!alone.withUnsafeBufferPointer { EastAsianWidth.isWide($0, at: 0) })
        #expect(!unpaired.withUnsafeBufferPointer { EastAsianWidth.isWide($0, at: 0) })
        #expect(pair.withUnsafeBufferPointer { EastAsianWidth.isWide($0, at: 0) })
    }
}
