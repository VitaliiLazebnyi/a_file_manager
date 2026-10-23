import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// The viewer's rows of a text without any window: the row index, and places in a row.
@Suite
internal struct ViewerModelRowTests {
    /// The rows of a whole text, cut in one go: what the index must agree with.
    private func referenceRows(_ data: Data, _ encoding: ViewerEncoding, _ options: TextLayoutOptions) -> [(
        start: Int64, startsLine: Bool
    )] {
        var text = DecodedText()
        let used = encoding.decode(data, final: true, into: &text)
        #expect(used == data.count)
        var rows: [(Int64, Bool)] = []
        var splitter = RowSplitter(options)
        text.units.withUnsafeBufferPointer { units in
            _ = splitter.split(units, final: true) { start, _, startsLine in
                rows.append((Int64(text.offsets[start]), startsLine))
                return true
            }
        }
        return rows
    }

    /// A document of the bytes in the encoding and layout, indexed in segments and chunks of the given sizes.
    private func document(
        _ data: Data,
        _ encoding: ViewerEncoding,
        _ layout: ViewerLayout,
        parallel: Bool = true,
        segment: Int = 4 << 20,
        chunk: Int = 1 << 20
    ) -> TextDocument {
        let document = TextDocument(
            source: DataByteSource(data),
            encoding: encoding,
            bomLength: 0,
            layout: layout,
            reusing: nil
        )
        document.buildIndex(
            parallel: parallel,
            scanning: TextRowIndex.ScanOptions(segmentSize: segment, chunkSize: chunk, rawScan: true)
        ) {
            // Not watched here.
        }
        return document
    }

    /// Text with every kind of line end, long lines, empty lines and characters of one to four bytes.
    private func syntheticText(lines: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let words = [
            "alpha", "beta", "γάμμα", "delta", "日本語", "x", "épsilon", "😀", "zeta",
            "a-very-long-word-without-any-space-in-it"
        ]
        var text = ""
        text.reserveCapacity(lines * 60)
        for number in 0..<lines {
            let count = number.isMultiple(of: 97) ? 400 : Int.random(in: 0...14, using: &generator)
            for index in 0..<count {
                text += words[Int.random(in: 0..<words.count, using: &generator)]
                text += index % 7 == 3 ? "\t" : " "
            }
            text += ["\n", "\r\n", "\r"][number.isMultiple(of: 3) ? Int.random(in: 0...2, using: &generator) : 0]
        }
        return text
    }

    // MARK: Rows

    /// Lines end with CR+LF, CR or LF; a final line end adds no row, and an empty file has none.
    @Test
    internal func linesEndWithCRLFOrCROrLF() throws {
        let data = Data("one\r\ntwo\rthree\n\nlast".utf8)
        let document = document(data, .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)))
        let rows = try document.rows(from: 0, count: 100, cancellation: nil)
        #expect(rows.map(\.text) == ["one", "two", "three", "", "last"])
        #expect(rows.map(\.line) == [1, 2, 3, 4, 5] && rows.allSatisfy(\.startsLine))
        #expect(
            rows.map(\.range) == [0..<5, 5..<9, 9..<15, 15..<16, 16..<20]
                && rows.map(\.contentEnd) == [3, 8, 14, 15, 20]
        )
        #expect(document.rowCount == 5 && document.lineCount == 5 && document.isIndexComplete)
        // A file that ends with a line end has no empty row behind it; an empty file has none.
        #expect(
            self.document(Data("a\n".utf8), .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)))
                .rowCount == 1
        )
        #expect(
            self.document(Data(), .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8))).rowCount
                == 0
        )
    }

    /// Long lines wrap at words or, without word wrap, are cut at the width; tabs are shown as spaces.
    @Test
    internal func longLinesWrapAtWordsOrAreCut() throws {
        let data = Data("the quick brown fox jumps\nabcdefghijklmnop\n\tx\ty".utf8)
        let wrapped = try document(data, .utf8, .text(TextLayoutOptions(columns: 10, wordWrap: true, tabWidth: 4)))
            .rows(from: 0, count: 100, cancellation: nil)
        #expect(wrapped.map(\.text) == ["the quick ", "brown fox ", "jumps", "abcdefghij", "klmnop", "    x   y"])
        #expect(
            wrapped.map(\.startsLine) == [true, false, false, true, false, true]
                && wrapped.map(\.line) == [1, 1, 1, 2, 2, 3]
        )
        let unwrapped = TextLayoutOptions(columns: 10, wordWrap: false, tabWidth: 8)
        let cut = try document(data, .utf8, .text(unwrapped)).rows(from: 0, count: 2, cancellation: nil)
        #expect(cut.map(\.text) == ["the quick ", "brown fox "])
        let hard = try document(
            Data("aaaaabbbbbccc".utf8),
            .utf8,
            .text(TextLayoutOptions(columns: 5, wordWrap: false, tabWidth: 8))
        )
        .rows(from: 0, count: 9, cancellation: nil)
        #expect(hard.map(\.text) == ["aaaaa", "bbbbb", "ccc"] && hard.map(\.range) == [0..<5, 5..<10, 10..<13])
        // A tab maps every space it is shown as to its one byte.
        #expect(wrapped[5].offsets == [0, 0, 0, 0, 1, 2, 2, 2, 3])
    }

    /// The index built in small segments and chunks, on one core or several, has the rows of cutting the whole text.
    @Test(arguments: [true, false])
    internal func theIndexBuiltInSegmentsEqualsCuttingTheWholeText(parallel: Bool) throws {
        let text = syntheticText(lines: 60_000)
        for encoding in [ViewerEncoding.utf8, .utf16LE] {
            let data = Data(try encoding.encode(text))
            for options in [
                TextLayoutOptions(columns: 72, wordWrap: true, tabWidth: 8),
                TextLayoutOptions(columns: 1_024, wordWrap: false, tabWidth: 8)
            ] {
                let reference = referenceRows(data, encoding, options)
                // Small segments and chunks, so that lines cross both many times.
                let document = document(
                    data,
                    encoding,
                    .text(options),
                    parallel: parallel,
                    segment: 96 * 1_024 + 2,
                    chunk: 8 * 1_024
                )
                #expect(document.isIndexComplete && document.rowCount == reference.count)
                #expect(document.lineCount == reference.filter(\.startsLine).count)
                var position = 0
                while position < reference.count {
                    let rows = try document.rows(from: position, count: 500, cancellation: nil)
                    let expected = reference[position..<min(reference.count, position + 500)]
                    #expect(
                        rows.map(\.range.lowerBound) == expected.map(\.start)
                            && rows.map(\.startsLine) == expected.map(\.startsLine),
                        "rows from \(position), \(encoding.name)"
                    )
                    position += 7_919
                }
                for row in [0, 63, 64, 65, reference.count / 2, reference.count - 1] {
                    #expect(try document.row(containing: reference[row].start, cancellation: nil) == row)
                    if row + 1 < reference.count {
                        #expect(try document.row(containing: reference[row + 1].start - 1, cancellation: nil) == row)
                    }
                }
                #expect(try document.row(containing: Int64(data.count), cancellation: nil) == reference.count - 1)
            }
        }
    }

    /// The index of 200,000 lines has one row per line, found by row and by line number.
    @Test
    internal func theIndexAgreesWithASimpleSplitAtLineEnds() throws {
        var lines: [String] = []
        for number in 0..<200_000 { lines.append("line \(number) " + String(repeating: "x", count: number % 50)) }
        let data = Data(lines.joined(separator: "\n").utf8)
        let document = document(
            data,
            .utf8,
            .text(TextLayoutOptions(columns: 1_024, wordWrap: false, tabWidth: 8)),
            segment: 256 * 1_024,
            chunk: 64 * 1_024
        )
        #expect(document.rowCount == lines.count && document.lineCount == lines.count)
        for row in [0, 1, 4_095, 77_777, 199_999] {
            #expect(try document.rows(from: row, count: 1, cancellation: nil).first?.text == lines[row])
            #expect(try document.row(ofLine: row + 1, cancellation: nil) == row)
        }
        #expect(try document.row(ofLine: 200_001, cancellation: nil) == nil)
        #expect(try document.rows(from: 199_998, count: 10, cancellation: nil).map(\.text) == Array(lines.suffix(2)))
    }

    /// A file without a line end is still cut into rows of the width.
    @Test
    internal func aFileWithoutLineEndsIsStillCutIntoRows() throws {
        let data = Data(repeating: 0x61, count: 300_000)
        let document = document(
            data,
            .ansi,
            .text(TextLayoutOptions(columns: 1_000, wordWrap: true, tabWidth: 8)),
            segment: 32 * 1_024,
            chunk: 4 * 1_024
        )
        #expect(document.rowCount == 300 && document.lineCount == 1)
        #expect(try document.rows(from: 299, count: 5, cancellation: nil).map(\.range) == [299_000..<300_000])
        #expect(try document.row(containing: 150_500, cancellation: nil) == 150)
    }

    /// A cancelled index stops and is not complete.
    @Test
    internal func indexingStopsWhenCancelled() {
        let document = TextDocument(
            source: DataByteSource(Data(repeating: 0x0A, count: 1 << 20)),
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        document.cancellation.cancel()
        document.buildIndex(
            parallel: true,
            scanning: TextRowIndex.ScanOptions(segmentSize: 64 * 1_024, chunkSize: 1 << 20, rawScan: true)
        ) {
            // Not watched here.
        }
        #expect(!document.isIndexComplete && document.rowCount == 0)
    }

    /// A byte order mark is not part of the text's rows, but the byte layouts show it.
    @Test
    internal func aByteOrderMarkIsNotPartOfTheText() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("first\nsecond".utf8))
        let document = TextDocument(
            source: DataByteSource(data),
            encoding: .utf8,
            bomLength: 3,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        document.buildIndex(parallel: false, scanning: .standard) {
            // Not watched here.
        }
        let rows = try document.rows(from: 0, count: 5, cancellation: nil)
        #expect(rows.map(\.text) == ["first", "second"] && rows[0].range == 3..<9)
        // The byte layouts show the file as it is.
        #expect(
            TextDocument(source: DataByteSource(data), encoding: .utf8, bomLength: 3, layout: .hex, reusing: nil)
                .content == 0..<15
        )
    }

    /// Places in a row of text map to bytes and back, through characters of every width and tabs.
    @Test
    internal func placesInARowMapToBytesAndBack() throws {
        let data = Data("aä😀\tz\n".utf8)
        let document = document(data, .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)))
        let row = try #require(try document.rows(from: 0, count: 1, cancellation: nil).first)
        #expect(row.text == "aä😀     z")
        // a = 1 byte, ä = 2, 😀 = 4 (two UTF-16 units), tab = 1 (five columns), z = 1.
        #expect((0...10).map { document.byteOffset(in: row, at: $0) } == [0, 1, 3, 3, 7, 7, 7, 7, 7, 8, 9])
        #expect(
            document.textIndex(in: row, of: 3) == 2 && document.textIndex(in: row, of: 8) == 9
                && document.textIndex(in: row, of: 9) == 10
        )
        #expect(document.textRanges(in: row, for: 1..<7) == [1..<4])
        #expect(try document.text(in: 1..<7, cancellation: nil) == "ä😀")
        #expect(try self.document(Data([0x41, 0x00, 0x42]), .ansi, .hex).text(in: 0..<3, cancellation: nil) == "A B")
    }
}
