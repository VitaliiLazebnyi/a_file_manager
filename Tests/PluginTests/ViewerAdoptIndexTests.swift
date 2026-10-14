import AFMKernel
import Foundation
import TestSupport
import Testing
@testable import ViewerPlugin

/// The row index: the raw scan of 16-bit text, lines of a few bytes, checkpoints that stay few,
/// and a new layout that takes over what the old one found.
@Suite struct ViewerAdoptIndex {
    private func signature(_ document: TextDocument) throws -> [String] {
        try document.rows(from: 0, count: document.rowCount).map { "\($0.range.lowerBound)-\($0.range.upperBound) \($0.startsLine) \($0.line) \($0.text)" }
    }

    private func index(_ data: Data, _ encoding: ViewerEncoding, _ options: TextLayoutOptions, raw: Bool, segment: Int, chunk: Int,
                       parallel: Bool = false) -> TextDocument {
        let document = TextDocument(source: DataByteSource(data), encoding: encoding, layout: .text(options))
        document.buildIndex(parallel: parallel, segmentSize: segment, chunkSize: chunk, rawScan: raw)
        return document
    }

    /// A text of many kinds of lines: short, long, tabs, every kind of line end, characters
    /// whose bytes look like line ends in 16-bit text, accents, CJK, characters beyond the BMP.
    private func jumble(seed: UInt64, lines: Int) -> String {
        var state = seed | 1
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(truncatingIfNeeded: state >> 9) % bound
        }
        let pieces = ["alpha ", "b", "\t", "  ", "größe ", "日本語 ", "😀", "\u{0A0A}", "\u{0D0D}", "\u{0A41}", "\u{410A}", "\u{0D41}", "x y z ", "a-very-long-word-without-spaces-in-it ",
                      "\u{0}", "\u{7}", "é"]
        let ends = ["\n", "\r\n", "\r", "\n\n", "\r\r\n"]
        var text = ""
        for number in 0..<lines {
            let count = number % 41 == 0 ? 60 + next(60) : next(8)
            for _ in 0..<count { text += pieces[next(pieces.count)] }
            text += number == lines - 1 && next(2) == 0 ? "" : ends[next(ends.count)]
        }
        return text
    }

    // MARK: 16-bit text

    @Test func rawScannedUTF16FindsTheRowsDecodingEverythingFinds() throws {
        let gbk = try #require(ViewerEncoding.codePage(936))
        for seed in [3, 4, 5] as [UInt64] {
            let text = jumble(seed: seed, lines: 500)
            for (encoding, bytes) in [(ViewerEncoding.utf16LE, ViewerEncoding.utf16LE.encode(text)), (.utf16BE, ViewerEncoding.utf16BE.encode(text)),
                                      (.utf8, ViewerEncoding.utf8.encode(text)), (gbk, gbk.encode(text.filter { gbk.encode(String($0)) != nil }))] {
                var data = Data(try #require(bytes))
                // A last unit that is cut in two, as a file can end.
                if seed == 5 { data.append(0x41) }
                for options in [TextLayoutOptions(columns: 20, wordWrap: true), TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 4),
                                TextLayoutOptions(columns: 33, wordWrap: false), TextLayoutOptions(columns: 500, wordWrap: true)] {
                    for (segment, chunk) in [(1 << 20, 1 << 20), (700, 61), (98, 16), (4096, 1000), (5000, 1)] {
                        let raw = index(data, encoding, options, raw: true, segment: segment, chunk: chunk, parallel: segment < 1000)
                        let decoded = index(data, encoding, options, raw: false, segment: segment, chunk: chunk, parallel: segment < 1000)
                        #expect(raw.rowCount == decoded.rowCount && raw.lineCount == decoded.lineCount, "\(encoding.name) \(options) \(segment)/\(chunk)")
                        #expect(try signature(raw) == signature(decoded), "\(encoding.name) \(options) \(segment)/\(chunk)")
                    }
                }
            }
        }
    }

    @Test func aLineOfCharactersThatCarryALineEndByteIsNotCut() throws {
        // U+0A0A is the bytes 0A 0A, U+410A is 0A 41 (little endian) or 41 0A (big endian): no line ends.
        let text = String(repeating: "\u{0A0A}\u{410A}\u{0D0D}\u{0A41}", count: 200) + "\nend"
        for encoding in [ViewerEncoding.utf16LE, .utf16BE] {
            let data = Data(try #require(encoding.encode(text)))
            let document = index(data, encoding, TextLayoutOptions(columns: 1000, wordWrap: false), raw: true, segment: 1 << 20, chunk: 1 << 20)
            #expect(document.lineCount == 2 && document.rowCount == 2, "\(encoding.name)")
            #expect(try document.rows(from: 0, count: 2).map(\.text) == [String(text.dropLast(4)).trimmingCharacters(in: .newlines), "end"])
        }
    }

    // MARK: Short lines and few checkpoints

    @Test func aFileOfNothingButLineEndsNeedsFewCheckpoints() throws {
        let data = Data(repeating: 0x0A, count: 16 << 20)
        let document = index(data, .utf8, TextLayoutOptions(columns: 80, wordWrap: true), raw: true, segment: 4 << 20, chunk: 1 << 20, parallel: true)
        #expect(document.rowCount == 16 << 20 && document.lineCount == 16 << 20)
        // One per 4 KB, not one per 64 rows.
        #expect(document.checkpointCount <= (16 << 20) / 4096 + 8 && document.checkpointCount >= 16)
        for row in [0, 1, 63, 64, 4095, 4096, 4097, 1_234_567, (16 << 20) - 1] {
            let found = try document.rows(from: row, count: 3)
            #expect(found.map(\.index) == Array(row..<min(16 << 20, row + 3)) && found.first?.range == Int64(row)..<Int64(row + 1))
            #expect(try document.row(containing: Int64(row)) == row)
            #expect(try document.row(ofLine: row + 1) == row)
        }
        // The same checkpoints on every path.
        let decoded = index(data.prefix(1 << 20), .utf8, TextLayoutOptions(columns: 80, wordWrap: true), raw: false, segment: 1 << 18, chunk: 1 << 16)
        let raw = index(data.prefix(1 << 20), .utf8, TextLayoutOptions(columns: 80, wordWrap: true), raw: true, segment: 1 << 18, chunk: 1 << 16)
        #expect(decoded.rowCount == raw.rowCount && raw.rowCount == 1 << 20)
        #expect(decoded.checkpointCount == raw.checkpointCount)
    }

    @Test func runsOfEmptyLinesAmongTextAreCountedLikeAnyOtherLines() throws {
        var text = ""
        for number in 0..<400 {
            text += "line \(number)\n" + String(repeating: "\n", count: number % 9 == 0 ? 3 + number % 70 : number % 3) + (number % 17 == 0 ? "\t\n" : "")
        }
        text += "\n\n\n\n\n\n"
        let data = Data(text.utf8)
        for options in [TextLayoutOptions(columns: 10, wordWrap: true), TextLayoutOptions(columns: 200, wordWrap: true)] {
            for (segment, chunk) in [(1 << 20, 1 << 20), (300, 37), (1000, 100), (97, 16)] {
                let raw = index(data, .utf8, options, raw: true, segment: segment, chunk: chunk, parallel: true)
                let decoded = index(data, .utf8, options, raw: false, segment: segment, chunk: chunk, parallel: true)
                #expect(try signature(raw) == signature(decoded), "\(options) \(segment)/\(chunk)")
            }
        }
    }

    @Test func plainLinesAreCutFromTheirBytesWithTheRowsOfTheDecodedText() throws {
        // ASCII only, so that the rows of long lines are cut from the bytes.
        var state: UInt64 = 99
        var text = ""
        for number in 0..<3000 {
            let length = number % 7 == 0 ? 300 : number % 5 == 0 ? 0 : Int(state >> 40) % 90
            state = state &* 6364136223846793005 &+ 1442695040888963407
            for position in 0..<length { text += position % 11 == 10 ? " " : position % 37 == 36 ? "\t" : "x" }
            text += ["\n", "\r\n", "\r"][number % 3]
        }
        let data = Data(text.utf8)
        for options in [TextLayoutOptions(columns: 40, wordWrap: true), TextLayoutOptions(columns: 77, wordWrap: false, tabWidth: 3), TextLayoutOptions(columns: 1, wordWrap: true)] {
            for (segment, chunk) in [(1 << 20, 1 << 20), (2000, 333), (101, 17)] {
                let raw = index(data, .utf8, options, raw: true, segment: segment, chunk: chunk)
                let decoded = index(data, .utf8, options, raw: false, segment: segment, chunk: chunk)
                #expect(try signature(raw) == signature(decoded), "\(options) \(segment)/\(chunk)")
            }
        }
    }

    // MARK: Taking over the rows of another layout

    @Test func aWiderLayoutTakesOverTheSegmentsWhoseLinesStillFitInOneRow() throws {
        // Eight segments of 40 KB: the line of 300 characters is in the fifth, all others are short.
        var lines: [String] = []
        var size = 0
        var number = 0
        while size < 320_000 {
            let line = number == 4000 ? String(repeating: "wide ", count: 60) : "short line \(number) with some text in it"
            lines.append(line)
            size += line.utf8.count + 1
            number += 1
        }
        let data = Data(lines.joined(separator: "\n").utf8)
        let source = DataByteSource(data)
        let narrow = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 100, wordWrap: true)))
        narrow.buildIndex(parallel: false, segmentSize: 40_000)
        #expect(narrow.segmentsReused == 0)
        let segments = (data.count + 39_999) / 40_000
        // 100 → 400 columns: every line fits both, so everything is taken over.
        let wide = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 400, wordWrap: true)), reusing: narrow)
        wide.buildIndex(parallel: true, segmentSize: 40_000)
        #expect(wide.segmentsReused == segments - 1, "the line of 300 characters did not fit 100 columns")
        let fresh = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 400, wordWrap: true)))
        fresh.buildIndex(parallel: true, segmentSize: 40_000)
        #expect(fresh.segmentsReused == 0)
        #expect(wide.rowCount == fresh.rowCount && wide.lineCount == fresh.lineCount && wide.rowCount == lines.count)
        #expect(try signature(wide) == signature(fresh))
        // Back to 100 columns from the wide one: the segment with the long line is read again.
        let back = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 100, wordWrap: true)), reusing: wide)
        back.buildIndex(parallel: false, segmentSize: 40_000)
        #expect(back.segmentsReused == segments - 1 && back.rowCount == narrow.rowCount)
        #expect(try signature(back) == signature(narrow))
        // 50 columns: lines of 41 characters still fit, so that is taken over too; 30: they do not.
        let fifty = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 50, wordWrap: true)), reusing: back)
        fifty.buildIndex(parallel: false, segmentSize: 40_000)
        #expect(fifty.segmentsReused == segments - 1)
        let thirty = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 30, wordWrap: true)), reusing: fifty)
        thirty.buildIndex(parallel: false, segmentSize: 40_000)
        let thirtyFresh = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 30, wordWrap: true)))
        thirtyFresh.buildIndex(parallel: false, segmentSize: 40_000)
        // (The 17 bytes behind the eighth segment hold no line start: nothing to read.)
        #expect(thirty.segmentsReused <= 1 && thirty.rowCount == thirtyFresh.rowCount && thirty.rowCount > lines.count)
        #expect(try signature(thirty) == signature(thirtyFresh))
    }

    @Test func nothingIsTakenOverFromAnotherTextAnotherEncodingOrAnotherTabWidth() throws {
        let data = Data((0..<2000).map { "line \($0)" }.joined(separator: "\n").utf8)
        let source = DataByteSource(data)
        let first = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        first.buildIndex(parallel: false, segmentSize: 4000)
        func relaid(_ source: ByteSource, _ encoding: ViewerEncoding, _ options: TextLayoutOptions, bom: Int = 0) -> TextDocument {
            let document = TextDocument(source: source, encoding: encoding, bomLength: bom, layout: .text(options), reusing: first)
            document.buildIndex(parallel: false, segmentSize: 4000)
            return document
        }
        let wide = TextLayoutOptions(columns: 200, wordWrap: true)
        #expect(relaid(source, .utf8, wide).segmentsReused > 0)
        // The same bytes in another source are not known to be the same.
        #expect(relaid(DataByteSource(data), .utf8, wide).segmentsReused == 0)
        #expect(relaid(source, .utf8, TextLayoutOptions(columns: 200, wordWrap: true, tabWidth: 4)).segmentsReused == 0)
        #expect(relaid(source, .ansi, wide).segmentsReused == 0)
        #expect(relaid(source, .utf8, wide, bom: 3).segmentsReused == 0)
        #expect(relaid(source, .utf8, wide).segmentsReused > 0)
        // An index that was cancelled is not a basis.
        let cut = TextDocument(source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        cut.cancellation.cancel()
        cut.buildIndex(parallel: false, segmentSize: 4000)
        let after = TextDocument(source: source, encoding: .utf8, layout: .text(wide), reusing: cut)
        after.buildIndex(parallel: false, segmentSize: 4000)
        #expect(after.segmentsReused == 0 && after.rowCount == 2000)
    }

    @Test func aSegmentRecordsTheWidestLineOrThatALineWasCut() throws {
        func widest(_ text: String, columns: Int) throws -> Int {
            let data = Data(text.utf8)
            return try TextRowIndex.scan(source: DataByteSource(data), content: 0..<Int64(data.count), segment: 0..<Int64(data.count), isFirst: true,
                                         encoding: .utf8, options: TextLayoutOptions(columns: columns, wordWrap: true), chunkSize: 1 << 20,
                                         cancellation: CancellationFlag()).widest
        }
        #expect(try widest("ab\nabcdef\nabc", columns: 80) == 6)
        #expect(try widest("a\tb\n", columns: 80) == 9)
        #expect(try widest("\n\n\n\n\n\n", columns: 80) == 0)
        #expect(try widest(String(repeating: "x", count: 100), columns: 80) == .max)
        #expect(try widest("ab\r\ncd\r\n", columns: 80) == 2)
    }
}
