import Foundation
import Testing

@testable import ViewerPlugin

/// The row index: the raw scan of 16-bit text, lines of a few bytes, and checkpoints that stay few.
@Suite
internal struct ViewerAdoptIndexTests {
    /// How a test builds an index: from the raw bytes or the decoded text, in segments and chunks of which size, and
    /// whether on several cores.
    internal struct Build {
        /// Whether the rows are found in the raw bytes rather than in the decoded text.
        internal let raw: Bool
        /// The bytes of a segment, the part of the text one task indexes.
        internal let segment: Int
        /// The bytes read at a time.
        internal let chunk: Int
        /// Whether the segments are indexed on several cores at once.
        internal let parallel: Bool
    }

    /// Indexes the bytes as a text of the encoding, laid out with the options, the way the build says.
    private func index(
        _ data: Data,
        _ encoding: ViewerEncoding,
        _ options: TextLayoutOptions,
        _ build: Build
    ) -> TextDocument {
        let document = TextDocument(
            source: DataByteSource(data),
            encoding: encoding,
            bomLength: 0,
            layout: .text(options),
            reusing: nil
        )
        document.buildIndex(
            parallel: build.parallel,
            scanning: TextRowIndex.ScanOptions(segmentSize: build.segment, chunkSize: build.chunk, rawScan: build.raw)
        ) {
            // Not watched here.
        }
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
        let pieces = [
            "alpha ", "b", "\t", "  ", "größe ", "日本語 ", "😀", "\u{0A0A}", "\u{0D0D}", "\u{0A41}", "\u{410A}",
            "\u{0D41}", "x y z ", "a-very-long-word-without-spaces-in-it ",
            "\u{0}", "\u{7}", "é"
        ]
        let ends = ["\n", "\r\n", "\r", "\n\n", "\r\r\n"]
        var text = ""
        for number in 0..<lines {
            let count = number.isMultiple(of: 41) ? 60 + next(60) : next(8)
            for _ in 0..<count { text += pieces[next(pieces.count)] }
            text += number == lines - 1 && next(2) == 0 ? "" : ends[next(ends.count)]
        }
        return text
    }

    // MARK: 16-bit text

    /// The raw scan of UTF-16 (both byte orders), UTF-8 and GBK finds the rows that decoding everything finds, for
    /// every layout and every segment and chunk size.
    @Test
    internal func rawScannedUTF16FindsTheRowsDecodingEverythingFinds() throws {
        let gbk = try #require(ViewerEncoding.codePage(936))
        for seed in [3, 4, 5] as [UInt64] {
            let text = jumble(seed: seed, lines: 500)
            for (encoding, bytes) in [
                (ViewerEncoding.utf16LE, try ViewerEncoding.utf16LE.encode(text)),
                (.utf16BE, try ViewerEncoding.utf16BE.encode(text)),
                (.utf8, try ViewerEncoding.utf8.encode(text)),
                (gbk, try gbk.encode(text.filter { (try? gbk.encode(String($0))) != nil }))
            ] {
                var data = Data(bytes)
                // A last unit that is cut in two, as a file can end.
                if seed == 5 { data.append(0x41) }
                for options in [
                    TextLayoutOptions(columns: 20, wordWrap: true, tabWidth: 8),
                    TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 4),
                    TextLayoutOptions(columns: 33, wordWrap: false, tabWidth: 8),
                    TextLayoutOptions(columns: 500, wordWrap: true, tabWidth: 8)
                ] {
                    for (segment, chunk) in [(1 << 20, 1 << 20), (700, 61), (98, 16), (4_096, 1_000), (5_000, 1)] {
                        let parallel = segment < 1_000
                        let raw = index(
                            data,
                            encoding,
                            options,
                            Build(raw: true, segment: segment, chunk: chunk, parallel: parallel)
                        )
                        let decoded = index(
                            data,
                            encoding,
                            options,
                            Build(raw: false, segment: segment, chunk: chunk, parallel: parallel)
                        )
                        #expect(
                            raw.rowCount == decoded.rowCount && raw.lineCount == decoded.lineCount,
                            "\(encoding.name) \(options) \(segment)/\(chunk)"
                        )
                        #expect(
                            try raw.signature() == decoded.signature(),
                            "\(encoding.name) \(options) \(segment)/\(chunk)"
                        )
                    }
                }
            }
        }
    }

    /// Characters of 16-bit text whose bytes are line end bytes do not end the line.
    @Test
    internal func aLineOfCharactersThatCarryALineEndByteIsNotCut() throws {
        // U+0A0A is the bytes 0A 0A, U+410A is 0A 41 (little endian) or 41 0A (big endian): no line ends.
        let text = String(repeating: "\u{0A0A}\u{410A}\u{0D0D}\u{0A41}", count: 200) + "\nend"
        for encoding in [ViewerEncoding.utf16LE, .utf16BE] {
            let data = Data(try encoding.encode(text))
            let document = index(
                data,
                encoding,
                TextLayoutOptions(columns: 1_000, wordWrap: false, tabWidth: 8),
                Build(raw: true, segment: 1 << 20, chunk: 1 << 20, parallel: false)
            )
            #expect(document.lineCount == 2 && document.rowCount == 2, "\(encoding.name)")
            #expect(
                try document.rows(from: 0, count: 2, cancellation: nil).map(\.text) == [
                    String(text.dropLast(4)).trimmingCharacters(in: .newlines), "end"
                ]
            )
        }
    }

    // MARK: Short lines and few checkpoints

    /// A file of 16 million line ends keeps about one checkpoint per 4 KB, finds every row from it, and has the same
    /// checkpoints on the raw and the decoding path.
    @Test
    internal func aFileOfNothingButLineEndsNeedsFewCheckpoints() throws {
        let data = Data(repeating: 0x0A, count: 16 << 20)
        let document = index(
            data,
            .utf8,
            TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8),
            Build(raw: true, segment: 4 << 20, chunk: 1 << 20, parallel: true)
        )
        #expect(document.rowCount == 16 << 20 && document.lineCount == 16 << 20)
        // One per 4 KB, not one per 64 rows.
        #expect(document.checkpointCount <= (16 << 20) / 4_096 + 8 && document.checkpointCount >= 16)
        for row in [0, 1, 63, 64, 4_095, 4_096, 4_097, 1_234_567, (16 << 20) - 1] {
            let found = try document.rows(from: row, count: 3, cancellation: nil)
            #expect(
                found.map(\.index) == Array(row..<min(16 << 20, row + 3))
                    && found.first?.range == Int64(row)..<Int64(row + 1)
            )
            #expect(try document.row(containing: Int64(row), cancellation: nil) == row)
            #expect(try document.row(ofLine: row + 1, cancellation: nil) == row)
        }
        // The same checkpoints on every path.
        let decoded = index(
            data.prefix(1 << 20),
            .utf8,
            TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8),
            Build(raw: false, segment: 1 << 18, chunk: 1 << 16, parallel: false)
        )
        let raw = index(
            data.prefix(1 << 20),
            .utf8,
            TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8),
            Build(raw: true, segment: 1 << 18, chunk: 1 << 16, parallel: false)
        )
        #expect(decoded.rowCount == raw.rowCount && raw.rowCount == 1 << 20)
        #expect(decoded.checkpointCount == raw.checkpointCount)
    }

    /// Runs of empty lines between lines of text give the same rows on the raw and the decoding path.
    @Test
    internal func runsOfEmptyLinesAmongTextAreCountedLikeAnyOtherLines() throws {
        var text = ""
        for number in 0..<400 {
            text +=
                "line \(number)\n"
                + String(repeating: "\n", count: number.isMultiple(of: 9) ? 3 + number % 70 : number % 3)
                + (number.isMultiple(of: 17) ? "\t\n" : "")
        }
        text += "\n\n\n\n\n\n"
        let data = Data(text.utf8)
        for options in [
            TextLayoutOptions(columns: 10, wordWrap: true, tabWidth: 8),
            TextLayoutOptions(columns: 200, wordWrap: true, tabWidth: 8)
        ] {
            for (segment, chunk) in [(1 << 20, 1 << 20), (300, 37), (1_000, 100), (97, 16)] {
                let raw = index(data, .utf8, options, Build(raw: true, segment: segment, chunk: chunk, parallel: true))
                let decoded = index(
                    data,
                    .utf8,
                    options,
                    Build(raw: false, segment: segment, chunk: chunk, parallel: true)
                )
                #expect(try raw.signature() == decoded.signature(), "\(options) \(segment)/\(chunk)")
            }
        }
    }

    /// The rows of plain ASCII lines, cut from their bytes, are the rows of the decoded text.
    @Test
    internal func plainLinesAreCutFromTheirBytesWithTheRowsOfTheDecodedText() throws {
        // ASCII only, so that the rows of long lines are cut from the bytes.
        var state: UInt64 = 99
        var text = ""
        for number in 0..<3_000 {
            let length = number.isMultiple(of: 7) ? 300 : number.isMultiple(of: 5) ? 0 : Int(state >> 40) % 90
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            for position in 0..<length { text += position % 11 == 10 ? " " : position % 37 == 36 ? "\t" : "x" }
            text += ["\n", "\r\n", "\r"][number % 3]
        }
        let data = Data(text.utf8)
        for options in [
            TextLayoutOptions(columns: 40, wordWrap: true, tabWidth: 8),
            TextLayoutOptions(columns: 77, wordWrap: false, tabWidth: 3),
            TextLayoutOptions(columns: 1, wordWrap: true, tabWidth: 8)
        ] {
            for (segment, chunk) in [(1 << 20, 1 << 20), (2_000, 333), (101, 17)] {
                let raw = index(data, .utf8, options, Build(raw: true, segment: segment, chunk: chunk, parallel: false))
                let decoded = index(
                    data,
                    .utf8,
                    options,
                    Build(raw: false, segment: segment, chunk: chunk, parallel: false)
                )
                #expect(try raw.signature() == decoded.signature(), "\(options) \(segment)/\(chunk)")
            }
        }
    }
}
