import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The viewer's logic without any window: detection, decoding block by block, the row index,
/// the hex and binary layouts, searching, and reading through a file-system provider.
@Suite struct ViewerModel {
    // MARK: Helpers

    /// Decodes `data` in pieces of `size` bytes, carrying what a piece leaves undecoded into
    /// the next, and returns the units with their offsets in the whole.
    func decodeInPieces(_ data: [UInt8], _ encoding: ViewerEncoding, size: Int) -> (units: [UInt16], offsets: [Int]) {
        var units: [UInt16] = []
        var offsets: [Int] = []
        var pending: [UInt8] = []
        var base = 0
        var position = 0
        var text = DecodedText()
        while position < data.count || !pending.isEmpty {
            let piece = data[position..<min(data.count, position + size)]
            position += piece.count
            pending += piece
            let used = encoding.decode(pending, final: position >= data.count, into: &text)
            units += text.units
            offsets += text.offsets.map { base + Int($0) }
            pending.removeFirst(used)
            base += used
            if position >= data.count, used == 0 { break }
        }
        return (units, offsets)
    }

    /// The rows of a whole text, cut in one go: what the index must agree with.
    func referenceRows(_ data: Data, _ encoding: ViewerEncoding, _ options: TextLayoutOptions) -> [(
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

    func document(
        _ data: Data, _ encoding: ViewerEncoding = .utf8, _ layout: ViewerLayout, parallel: Bool = true,
        segment: Int = 4 << 20,
        chunk: Int = 1 << 20
    ) -> TextDocument {
        let document = TextDocument(source: DataByteSource(data), encoding: encoding, layout: layout)
        document.buildIndex(parallel: parallel, segmentSize: segment, chunkSize: chunk)
        return document
    }

    func find(
        _ text: String, _ options: SearchOptions = SearchOptions(), in data: Data, from start: Int64 = 0,
        encoding: ViewerEncoding = .utf8,
        chunk: Int = 1 << 20
    ) throws -> Range<Int64>? {
        let pattern = try SearchPattern(text, options: options, encoding: encoding)
        return try ViewerSearch.find(
            pattern, in: DataByteSource(data), content: 0..<Int64(data.count), from: start,
            backwards: options.backwards,
            encoding: encoding, chunkSize: chunk)
    }

    // MARK: Detection

    @Test func byteOrderMarksNameTheEncoding() {
        #expect(
            ViewerDetection.guessText(Data([0xEF, 0xBB, 0xBF, 0x41]), isWholeFile: true)
                == .init(encoding: .utf8, bomLength: 3))
        #expect(
            ViewerDetection.guessText(Data([0xFF, 0xFE, 0x41, 0x00]), isWholeFile: true)
                == .init(encoding: .utf16LE, bomLength: 2))
        #expect(
            ViewerDetection.guessText(Data([0xFE, 0xFF, 0x00, 0x41]), isWholeFile: true)
                == .init(encoding: .utf16BE, bomLength: 2))
    }

    @Test func textEncodingsAreGuessedFromTheContent() {
        func guess(_ bytes: [UInt8], whole: Bool = true) -> ViewerDetection.TextGuess {
            ViewerDetection.guessText(Data(bytes), isWholeFile: whole)
        }
        #expect(guess(Array("plain text\r\n".utf8)).encoding == .utf8)
        #expect(guess(Array("Größe 5 €".utf8)).encoding == .utf8)
        // A sample cut off in the middle of a character is still UTF-8; a whole file is not.
        let cut = Array(Array("Größe €".utf8).dropLast())
        #expect(guess(cut, whole: false).encoding == .utf8)
        #expect(guess(cut, whole: true).encoding != .utf8)
        #expect(guess(ViewerEncoding.utf16LE.encode("Hello, world\r\n")!).encoding == .utf16LE)
        #expect(guess(ViewerEncoding.utf16BE.encode("Hello, world\r\n")!).encoding == .utf16BE)
        // Windows: accented letters inside words. DOS: frames, and letters where Windows has none.
        #expect(guess(ViewerEncoding.ansi.encode("Größe und Maße, déjà vu")!) == .init(encoding: .ansi))
        #expect(
            guess(ViewerEncoding.dos.encode("╔════════╗\r\n║ Gr\u{F6}\u{DF}e  ║\r\n╚════════╝")!)
                == .init(encoding: .dos))
        #expect(guess([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04]).isBinary)
        #expect(guess([0x01, 0x02, 0x03, 0x04, 0x41, 0x05, 0x06, 0x07]).isBinary)
        #expect(!guess(Array("tab\tand\u{1B}[0m escape".utf8)).isBinary)
        #expect(guess([]).encoding == .utf8)
    }

    @Test func contentKindsComeFromNameAndFirstBytes() {
        func kind(_ name: String, _ head: [UInt8] = []) -> ViewerDetection.Content {
            ViewerDetection.content(name: name, sample: Data(head))
        }
        #expect(
            kind("a.PNG") == .image && kind("noext", [0x89, 0x50, 0x4E, 0x47]) == .image
                && kind("x.dat", [0xFF, 0xD8, 0xFF, 0xE0]) == .image)
        #expect(kind("song.mp3") == .media && kind("clip.MOV") == .media)
        #expect(kind("doc.bin", Array("%PDF-1.7".utf8)) == .pdf && kind("x.txt", Array("{\\rtf1\\ansi".utf8)) == .rtf)
        #expect(kind("index.htm") == .html && kind("page", Array("  <!DOCTYPE html><html>".utf8)) == .html)
        #expect(kind("notes.txt", Array("hello".utf8)) == .other)
        #expect(
            ViewerDetection.content(
                name: "a.mkv", sample: Data(), additionalMedia: ViewerDetection.extensions(in: "*.mkv *.wmv"))
                == .media)
        #expect(ViewerDetection.content(name: "a.jpg", sample: Data([0xFF, 0xD8, 0xFF]), vetoed: ["jpg"]) == .other)
        #expect(
            ViewerDetection.htmlCharset(
                Data("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1251\">".utf8))?.codePage
                == 1_251)
        #expect(ViewerDetection.htmlCharset(Data("<meta charset='UTF-8'>".utf8)) == .utf8)
    }

    // MARK: Decoding

    @Test func decodingBlockByBlockEqualsDecodingAtOnce() throws {
        let sample = "ASCII, Größe, 日本語のテキスト, emoji 😀🎉, tab\tend\r\n"
        let cases: [(ViewerEncoding, [UInt8])] = [
            (.utf8, Array(sample.utf8)), (.utf16LE, try #require(ViewerEncoding.utf16LE.encode(sample))),
            (.utf16BE, try #require(ViewerEncoding.utf16BE.encode(sample))),
            (
                try #require(ViewerEncoding.codePage(932)),
                try #require(ViewerEncoding.codePage(932)?.encode("ABC 日本語のテキスト xyz ｶﾀｶﾅ"))
            ),
            (.ansi, try #require(ViewerEncoding.ansi.encode("Größe € déjà"))),
            (.dos, try #require(ViewerEncoding.dos.encode("╔═╗ Größe")))
        ]
        for (encoding, bytes) in cases {
            var whole = DecodedText()
            #expect(encoding.decode(bytes, final: true, into: &whole) == bytes.count)
            #expect(!whole.units.contains(CodeTable.replacement), "\(encoding.name)")
            for size in 1...9 {
                let pieces = decodeInPieces(bytes, encoding, size: size)
                #expect(pieces.units == whole.units, "\(encoding.name), pieces of \(size)")
                #expect(pieces.offsets == whole.offsets.map(Int.init), "\(encoding.name), pieces of \(size)")
            }
        }
        #expect(ViewerEncoding.utf8.string(from: Data(sample.utf8)) == sample)
        #expect(ViewerEncoding.dos.string(from: Data([0xC9, 0xCD, 0xBB, 0x84])) == "╔═╗ä")
        #expect(ViewerEncoding.macRoman.string(from: Data([0x8A, 0xA5])) == "ä•")
    }

    @Test func aCharacterCutOffAtTheEndWaitsForItsRest() {
        var text = DecodedText()
        let euro: [UInt8] = [0x41, 0xE2, 0x82]
        #expect(ViewerEncoding.utf8.decode(euro, final: false, into: &text) == 1 && text.units == [0x41])
        #expect(
            ViewerEncoding.utf8.decode(euro, final: true, into: &text) == 3 && text.units == [0x41, 0xFFFD, 0xFFFD])
        // Half a surrogate pair, and half a code unit.
        #expect(ViewerEncoding.utf16LE.decode([0x41, 0x00, 0x3D, 0xD8], final: false, into: &text) == 2)
        #expect(ViewerEncoding.utf16LE.decode([0x41, 0x00, 0x42], final: false, into: &text) == 2)
        #expect(
            ViewerEncoding.utf16LE.decode([0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE], final: false, into: &text) == 6
                && text.string == "A😀")
        #expect(text.offsets == [0, 2, 2])
    }

    @Test func malformedInputBecomesReplacementCharactersAndKeepsItsOffsets() {
        var text = DecodedText()
        // An overlong form, a lone continuation byte, a surrogate, a value beyond U+10FFFF.
        let bytes: [UInt8] = [0x41, 0xC0, 0x80, 0x80, 0xED, 0xA0, 0x80, 0xF5, 0x42]
        #expect(ViewerEncoding.utf8.decode(bytes, final: true, into: &text) == bytes.count)
        #expect(
            text.units.first == 0x41 && text.units.last == 0x42
                && text.units.dropFirst().dropLast().allSatisfy { $0 == 0xFFFD })
        #expect(text.offsets == [0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(
            ViewerEncoding.utf16LE.decode([0x00, 0xDC, 0x41, 0x00], final: true, into: &text) == 4
                && text.units == [0xFFFD, 0x41])
        // A lead byte of a double-byte page before a line end does not swallow the line end.
        let japanese = ViewerEncoding.codePage(932)
        #expect(
            japanese?.decode([0x83, 0x0A, 0x41], final: true, into: &text) == 3 && text.units == [0xFFFD, 0x0A, 0x41])
    }

    // MARK: Rows

    @Test func linesEndWithCRLFOrCROrLF() throws {
        let data = Data("one\r\ntwo\rthree\n\nlast".utf8)
        let document = document(data, .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        let rows = try document.rows(from: 0, count: 100)
        #expect(rows.map(\.text) == ["one", "two", "three", "", "last"])
        #expect(rows.map(\.line) == [1, 2, 3, 4, 5] && rows.allSatisfy(\.startsLine))
        #expect(
            rows.map(\.range) == [0..<5, 5..<9, 9..<15, 15..<16, 16..<20]
                && rows.map(\.contentEnd) == [3, 8, 14, 15, 20])
        #expect(document.rowCount == 5 && document.lineCount == 5 && document.isIndexComplete)
        // A file that ends with a line end has no empty row behind it; an empty file has none.
        #expect(
            self.document(Data("a\n".utf8), .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true))).rowCount == 1)
        #expect(self.document(Data(), .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true))).rowCount == 0)
    }

    @Test func longLinesWrapAtWordsOrAreCut() throws {
        let data = Data("the quick brown fox jumps\nabcdefghijklmnop\n\tx\ty".utf8)
        let wrapped = try document(data, .utf8, .text(TextLayoutOptions(columns: 10, wordWrap: true, tabWidth: 4)))
            .rows(from: 0, count: 100)
        #expect(wrapped.map(\.text) == ["the quick ", "brown fox ", "jumps", "abcdefghij", "klmnop", "    x   y"])
        #expect(
            wrapped.map(\.startsLine) == [true, false, false, true, false, true]
                && wrapped.map(\.line) == [1, 1, 1, 2, 2, 3])
        let cut = try document(data, .utf8, .text(TextLayoutOptions(columns: 10, wordWrap: false))).rows(
            from: 0, count: 2)
        #expect(cut.map(\.text) == ["the quick ", "brown fox "])
        let hard = try document(
            Data("aaaaabbbbbccc".utf8), .utf8, .text(TextLayoutOptions(columns: 5, wordWrap: false))
        ).rows(from: 0, count: 9)
        #expect(hard.map(\.text) == ["aaaaa", "bbbbb", "ccc"] && hard.map(\.range) == [0..<5, 5..<10, 10..<13])
        // A tab maps every space it is shown as to its one byte.
        #expect(wrapped[5].offsets == [0, 0, 0, 0, 1, 2, 2, 2, 3])
    }

    /// Text with every kind of line end, long lines, empty lines and characters of one to four bytes.
    func syntheticText(lines: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let words = [
            "alpha", "beta", "γάμμα", "delta", "日本語", "x", "épsilon", "😀", "zeta",
            "a-very-long-word-without-any-space-in-it"
        ]
        var text = ""
        text.reserveCapacity(lines * 60)
        for number in 0..<lines {
            let count = number % 97 == 0 ? 400 : Int.random(in: 0...14, using: &generator)
            for index in 0..<count {
                text += words[Int.random(in: 0..<words.count, using: &generator)]
                text += index % 7 == 3 ? "\t" : " "
            }
            text += ["\n", "\r\n", "\r"][number % 3 == 0 ? Int.random(in: 0...2, using: &generator) : 0]
        }
        return text
    }

    @Test(arguments: [true, false])
    func theIndexBuiltInSegmentsEqualsCuttingTheWholeText(parallel: Bool) throws {
        let text = syntheticText(lines: 60_000)
        for encoding in [ViewerEncoding.utf8, .utf16LE] {
            let data = Data(try #require(encoding.encode(text)))
            for options in [
                TextLayoutOptions(columns: 72, wordWrap: true), TextLayoutOptions(columns: 1_024, wordWrap: false)
            ] {
                let reference = referenceRows(data, encoding, options)
                // Small segments and chunks, so that lines cross both many times.
                let document = document(
                    data, encoding, .text(options), parallel: parallel, segment: 96 * 1_024 + 2, chunk: 8 * 1_024)
                #expect(document.isIndexComplete && document.rowCount == reference.count)
                #expect(document.lineCount == reference.filter(\.startsLine).count)
                var position = 0
                while position < reference.count {
                    let rows = try document.rows(from: position, count: 500)
                    let expected = reference[position..<min(reference.count, position + 500)]
                    #expect(
                        rows.map(\.range.lowerBound) == expected.map(\.start)
                            && rows.map(\.startsLine) == expected.map(\.startsLine),
                        "rows from \(position), \(encoding.name)")
                    position += 7_919
                }
                for row in [0, 63, 64, 65, reference.count / 2, reference.count - 1] {
                    #expect(try document.row(containing: reference[row].start) == row)
                    if row + 1 < reference.count {
                        #expect(try document.row(containing: reference[row + 1].start - 1) == row)
                    }
                }
                #expect(try document.row(containing: Int64(data.count)) == reference.count - 1)
            }
        }
    }

    @Test func theIndexAgreesWithASimpleSplitAtLineEnds() throws {
        var lines: [String] = []
        for number in 0..<200_000 { lines.append("line \(number) " + String(repeating: "x", count: number % 50)) }
        let data = Data(lines.joined(separator: "\n").utf8)
        let document = document(
            data, .utf8, .text(TextLayoutOptions(columns: 1_024, wordWrap: false)), segment: 256 * 1_024,
            chunk: 64 * 1_024)
        #expect(document.rowCount == lines.count && document.lineCount == lines.count)
        for row in [0, 1, 4_095, 77_777, 199_999] {
            #expect(try document.rows(from: row, count: 1).first?.text == lines[row])
            #expect(try document.row(ofLine: row + 1) == row)
        }
        #expect(try document.row(ofLine: 200_001) == nil)
        #expect(try document.rows(from: 199_998, count: 10).map(\.text) == Array(lines.suffix(2)))
    }

    @Test func aFileWithoutLineEndsIsStillCutIntoRows() throws {
        let data = Data(repeating: 0x61, count: 300_000)
        let document = document(
            data, .ansi, .text(TextLayoutOptions(columns: 1_000, wordWrap: true)), segment: 32 * 1_024, chunk: 4 * 1_024
        )
        #expect(document.rowCount == 300 && document.lineCount == 1)
        #expect(try document.rows(from: 299, count: 5).map(\.range) == [299_000..<300_000])
        #expect(try document.row(containing: 150_500) == 150)
    }

    @Test func indexingStopsWhenCancelled() {
        let document = TextDocument(
            source: DataByteSource(Data(repeating: 0x0A, count: 1 << 20)), encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        document.cancellation.cancel()
        document.buildIndex(parallel: true, segmentSize: 64 * 1_024)
        #expect(!document.isIndexComplete && document.rowCount == 0)
    }

    @Test func aByteOrderMarkIsNotPartOfTheText() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("first\nsecond".utf8))
        let document = TextDocument(
            source: DataByteSource(data), encoding: .utf8, bomLength: 3,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        document.buildIndex(parallel: false)
        let rows = try document.rows(from: 0, count: 5)
        #expect(rows.map(\.text) == ["first", "second"] && rows[0].range == 3..<9)
        // The byte layouts show the file as it is.
        #expect(
            TextDocument(source: DataByteSource(data), encoding: .utf8, bomLength: 3, layout: .hex).content == 0..<15)
    }

    // MARK: Hex and binary

    @Test func hexRowsLookAsInTheSpecification() throws {
        let data = Data("Report 1\r\nLorem ipsum dolor".utf8)
        let document = document(data, .ansi, .hex)
        let rows = try document.rows(from: 0, count: 10)
        #expect(
            rows.map(\.text) == [
                "00000000: 52 65 70 6F 72 74 20 31|0D 0A 4C 6F 72 65 6D 20 | Report 1..Lorem ",
                "00000010: 69 70 73 75 6D 20 64 6F|6C 6F 72                | ipsum dolor"
            ])
        #expect(document.rowCount == 2 && rows[1].range == 16..<27)
        let short = try self.document(Data([0x0D, 0x0A]), .ansi, .hex).rows(from: 0, count: 1)
        #expect(short[0].text == "00000000: 0D 0A" + String(repeating: " ", count: 43) + "| ..")
        #expect(
            HexFormat(length: 0x1_0000_0000).offsetDigits == 8 && HexFormat(length: 0x1_0000_0001).offsetDigits == 9)
        #expect(HexFormat.hexString(Data([0x52, 0x65, 0x00, 0xFF])) == "52 65 00 FF")
    }

    @Test func aSelectionShowsInBothPartsOfAHexRow() throws {
        let document = document(Data((0..<40).map { UInt8($0 + 0x30) }), .ansi, .hex)
        let row = try #require(try document.rows(from: 1, count: 1).first)
        // Bytes 18…20 of the file are the third to fifth of the second row.
        #expect(document.textRanges(in: row, for: 18..<21) == [16..<24, 62..<65])
        #expect(document.textRanges(in: row, for: 0..<16).isEmpty)
        #expect(
            document.byteOffset(in: row, at: 16) == 18 && document.byteOffset(in: row, at: 17) == 18
                && document.byteOffset(in: row, at: 63) == 19)
        #expect(document.byteOffset(in: row, at: 0) == 16 && document.byteOffset(in: row, at: 500) == 32)
        #expect(document.textIndex(in: row, of: 20) == 22)
    }

    @Test func binaryRowsHaveAFixedLengthAndDotsForControlCharacters() throws {
        let data = Data(Array("ab\r\ncd\u{0}ef".utf8) + [0xE4, 0xFF])
        let document = document(data, .ansi, .binary(width: 4))
        #expect(document.rowCount == 3)
        let rows = try document.rows(from: 0, count: 10)
        #expect(rows.map(\.text) == ["ab..", "cd.e", "fäÿ"] && rows.map(\.range) == [0..<4, 4..<8, 8..<11])
        #expect(try document.row(containing: 9) == 2 && document.row(ofLine: 2) == 1)
        #expect(document.textRanges(in: rows[1], for: 5..<9) == [1..<4])
        // In another character set the same bytes are other characters.
        #expect(
            try self.document(Data([0xC9, 0xCD, 0xBB]), .dos, .binary(width: 75)).rows(from: 0, count: 1).first?.text
                == "╔═╗")
        // A multi-byte encoding falls back to one byte per character.
        #expect(self.document(data, .utf8, .binary(width: 4)).encoding == .ansi)
    }

    @Test func placesInARowMapToBytesAndBack() throws {
        let data = Data("aä😀\tz\n".utf8)
        let document = document(data, .utf8, .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        let row = try #require(try document.rows(from: 0, count: 1).first)
        #expect(row.text == "aä😀     z")
        // a = 1 byte, ä = 2, 😀 = 4 (two UTF-16 units), tab = 1 (five columns), z = 1.
        #expect((0...10).map { document.byteOffset(in: row, at: $0) } == [0, 1, 3, 3, 7, 7, 7, 7, 7, 8, 9])
        #expect(
            document.textIndex(in: row, of: 3) == 2 && document.textIndex(in: row, of: 8) == 9
                && document.textIndex(in: row, of: 9) == 10)
        #expect(document.textRanges(in: row, for: 1..<7) == [1..<4])
        #expect(try document.text(in: 1..<7) == "ä😀")
        #expect(try self.document(Data([0x41, 0x00, 0x42]), .ansi, .hex).text(in: 0..<3) == "A B")
    }

    // MARK: Search

    @Test func plainTextSearchWithItsSwitches() throws {
        let data = Data("The manager met a man. MAN overboard! Tab\there.\r\nNext line\nback\\slash".utf8)
        #expect(try find("man", in: data) == 4..<7)
        #expect(try find("man", SearchOptions(wholeWords: true), in: data) == 18..<21)
        #expect(try find("MAN", SearchOptions(caseSensitive: true), in: data) == 23..<26)
        #expect(try find("man", in: data, from: 5) == 18..<21)
        #expect(try find("man", SearchOptions(backwards: true), in: data, from: Int64(data.count)) == 23..<26)
        #expect(try find("man", SearchOptions(backwards: true), in: data, from: 23) == 18..<21)
        #expect(try find("man", SearchOptions(wholeWords: true, backwards: true), in: data, from: 18) == nil)
        #expect(try find("Tab\\there", in: data) == 38..<46)
        // `\n` finds a line end of either kind; `\\` one backslash.
        #expect(try find("here.\\nnext", in: data) == 42..<53)
        #expect(try find("line\\nback\\\\slash", in: data) == 54..<69)
        #expect(try find("absent", in: data) == nil)
        #expect(throws: SearchError.empty) { try find("", in: data) }
    }

    @Test func hexSearchTakesBytesAndQuotedText() throws {
        let data = Data([0x00, 0x50, 0x4B, 0x01, 0x02, 0xFF, 0x50, 0x4B, 0x03, 0x04])
        let hex = SearchOptions(hex: true)
        #expect(try find("01 02 FF", hex, in: data) == 3..<6)
        #expect(try find("\"PK\"0304", hex, in: data) == 6..<10)
        #expect(try find("\"PK\"", hex, in: data, from: 2) == 6..<8)
        #expect(try find("504b", SearchOptions(backwards: true, hex: true), in: data, from: 10) == 6..<8)
        #expect(try find("504b", SearchOptions(backwards: true, hex: true), in: data, from: 6) == 1..<3)
        #expect(try find("AA", hex, in: data) == nil)
        #expect(throws: SearchError.self) { try find("0G", hex, in: data) }
        #expect(throws: SearchError.self) { try find("012", hex, in: data) }
        #expect(try SearchPattern.hexBytes("\"é\"0A", encoding: .ansi) == [0xE9, 0x0A])
    }

    @Test func regularExpressions() throws {
        let data = Data("id=17; id=2048\nname = Smith\nNAME = Jones".utf8)
        let regex = SearchOptions(regex: true)
        #expect(try find("id=\\d{3,}", regex, in: data) == 7..<14)
        #expect(try find("^name\\s*=\\s*\\w+$", regex, in: data) == 15..<27)
        #expect(
            try find(
                "^name", SearchOptions(caseSensitive: true, backwards: true, regex: true), in: data,
                from: Int64(data.count)) == 15..<19)
        #expect(
            try find("^name", SearchOptions(backwards: true, regex: true), in: data, from: Int64(data.count)) == 28..<32
        )
        #expect(throws: SearchError.self) { try find("(unclosed", regex, in: data) }
    }

    @Test func searchingInOtherEncodingsGivesByteRanges() throws {
        let text = "Zeile eins\r\nGrößenwahn und Ärger"
        let wide = Data(try #require(ViewerEncoding.utf16LE.encode(text)))
        #expect(try find("größenwahn", in: wide, encoding: .utf16LE) == 24..<44)
        #expect(
            try find("ärger", SearchOptions(backwards: true), in: wide, from: Int64(wide.count), encoding: .utf16LE)
                == 54..<64)
        // From an odd offset the search still reads whole code units.
        #expect(try find("und", in: wide, from: 25, encoding: .utf16LE) == 46..<52)
        let dos = Data(try #require(ViewerEncoding.dos.encode(text)))
        #expect(try find("Größe", SearchOptions(caseSensitive: true), in: dos, encoding: .dos) == 12..<17)
        let utf8 = Data(text.utf8)
        #expect(try find("ärger", in: utf8) == 29..<35)
    }

    @Test(arguments: [false, true])
    func matchesAcrossChunkBordersAreFound(backwards: Bool) throws {
        // Chunks of 64 bytes: the needle lies across the border at 4096 and, in UTF-8, the
        // border even splits a character of it.
        var text = String(repeating: "abcdefg ", count: 511) + "abc Grüße aus Köln, 日本 "
        text += String(repeating: "hijklmn ", count: 300)
        let data = Data(text.utf8)
        let expected = try #require(text.range(of: "Grüße aus Köln, 日本"))
        let range =
            Int64(
                text.utf8.distance(from: text.startIndex, to: expected.lowerBound))..<Int64(
                text.utf8.distance(from: text.startIndex, to: expected.upperBound))
        let start = backwards ? Int64(data.count) : 0
        for chunk in [64, 100, 4_096, 1 << 20] {
            #expect(
                try find(
                    "grüße aus köln, 日本", SearchOptions(backwards: backwards), in: data, from: start, chunk: chunk)
                    == range, "chunk \(chunk)")
            #expect(
                try find(
                    "Gr.ße\\s+aus\\s+K\\wln", SearchOptions(backwards: backwards, regex: true), in: data, from: start,
                    chunk: chunk)?.lowerBound
                    == range.lowerBound, "chunk \(chunk)")
            #expect(
                try find(
                    "\"Gr\"C3BC\"\"C39F", SearchOptions(backwards: backwards, hex: true), in: data, from: start,
                    chunk: chunk)
                    == range.lowerBound..<range.lowerBound + 6, "chunk \(chunk)")
            let wide = Data(try #require(ViewerEncoding.utf16LE.encode(text)))
            let found = try find(
                "aus köln", SearchOptions(backwards: backwards), in: wide, from: backwards ? Int64(wide.count) : 0,
                encoding: .utf16LE, chunk: chunk)
            #expect(
                found.map {
                    ViewerEncoding.utf16LE.string(from: wide.subdata(in: Int($0.lowerBound)..<Int($0.upperBound)))
                } == "aus Köln")
        }
    }

    @Test func everyOccurrenceIsFoundOnceInOrder() throws {
        var bytes = [UInt8](repeating: 0x2E, count: 200_000)
        let places = [0, 61, 64, 4_090, 65_535, 65_540, 131_070, 199_997]
        for place in places { bytes.replaceSubrange(place..<place + 3, with: Array("hit".utf8)) }
        let data = Data(bytes)
        for options in [SearchOptions(), SearchOptions(hex: true), SearchOptions(regex: true)] {
            let needle = options.hex ? "686974" : "hit"
            var found: [Int] = []
            var start: Int64 = 0
            while let match = try find(needle, options, in: data, from: start, chunk: 1 << 16) {
                found.append(Int(match.lowerBound))
                start = match.lowerBound + 1
            }
            #expect(found == places)
            var backwards = options
            backwards.backwards = true
            found = []
            start = Int64(data.count)
            while let match = try find(needle, backwards, in: data, from: start, chunk: 1 << 16) {
                found.append(Int(match.lowerBound))
                start = match.lowerBound
            }
            #expect(found == places.reversed())
        }
    }

    @Test func aCancelledSearchFindsNothingAndProgressIsReported() throws {
        let data = Data(repeating: 0x61, count: 1 << 20) + Data("needle".utf8)
        let pattern = try SearchPattern("needle", options: SearchOptions(), encoding: .utf8)
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            try ViewerSearch.find(
                pattern, in: DataByteSource(data), content: 0..<Int64(data.count), from: 0, backwards: false,
                encoding: .utf8,
                chunkSize: 4_096, cancellation: cancelled) == nil)
        var reports: [Double] = []
        let found = try ViewerSearch.find(
            pattern, in: DataByteSource(data), content: 0..<Int64(data.count), from: 0, backwards: false,
            encoding: .utf8,
            chunkSize: 4_096, parallelism: 4
        ) { reports.append($0) }
        #expect(found == Int64(1 << 20)..<Int64((1 << 20) + 6))
        #expect(reports.count > 10 && reports == reports.sorted() && (reports.last ?? 2) <= 1)
    }

    // MARK: Reading through a provider

    /// A file of `count` bytes in a memory file system: byte `i` is `i % 251`.
    func memoryFile(_ count: Int) throws -> (FileSystemRegistry, MemoryFileSystem, URL, Data) {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        let data = Data((0..<count).map { UInt8($0 % 251) })
        let url = memory.url("/dir/blob.bin")
        try memory.createDirectory(at: memory.url("/dir"))
        let writer = try memory.write(url)
        try writer.write(data)
        try writer.close(attributes: FileAttributes())
        return (registry, memory, url, data)
    }

    @Test func filesAreReadThroughTheirProviderWithSeek() throws {
        let (registry, _, url, data) = try memoryFile(300_000)
        let source = try ProviderByteSource.open(url, fileSystems: registry)
        #expect(source is ProviderByteSource && source.length == 300_000)
        #expect(try source.read(at: 0, count: 10) == data.prefix(10))
        #expect(try source.read(at: 299_990, count: 100) == data.suffix(10))
        #expect(try source.read(250_000..<250_300) == data.subdata(in: 250_000..<250_300))
        #expect(try source.read(at: 400_000, count: 5).isEmpty)
        // Many threads at once, each through a reader of its own.
        let cached = CachedByteSource(source, blockSize: 4_096, capacity: 8)
        let pieces = Parallel.map(Array(0..<400)) { number -> Bool in
            let lower = (number * 7_919) % 290_000
            let length = 1 + (number * 131) % 9_000
            return (try? cached.read(at: Int64(lower), count: length)) == data.subdata(in: lower..<lower + length)
        }
        #expect(pieces.allSatisfy { $0 })
        #expect(
            try cached.read(at: 299_999, count: 50) == data.suffix(1) && cached.read(at: 300_000, count: 1).isEmpty)
        source.close()
        #expect(try source.read(at: 5, count: 3) == data.subdata(in: 5..<8))
        #expect(throws: (any Error).self) {
            try ProviderByteSource.open(URL(string: "mem:///missing.txt")!, fileSystems: registry)
        }
    }

    @Test func aTextOnAnotherFileSystemIsIndexedSearchedAndShown() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        var lines: [String] = []
        for number in 1...30_000 { lines.append("Zeile \(number): Größe \(number * 3)") }
        let url = memory.addFile("/texts/long.txt", lines.joined(separator: "\r\n"))
        let source = CachedByteSource(try ProviderByteSource.open(url, fileSystems: registry))
        let guess = ViewerDetection.guessText(
            try source.read(at: 0, count: ViewerDetection.sampleSize), isWholeFile: false)
        #expect(guess.encoding == .utf8 && !guess.isBinary)
        let document = TextDocument(
            source: source, encoding: guess.encoding, layout: .text(TextLayoutOptions(columns: 200, wordWrap: true)))
        document.buildIndex(parallel: true, segmentSize: 100_000, chunkSize: 10_000)
        #expect(document.rowCount == 30_000)
        #expect(
            try document.rows(from: 29_998, count: 5).map(\.text) == [
                "Zeile 29999: Größe 89997", "Zeile 30000: Größe 90000"
            ])
        let pattern = try SearchPattern("zeile 22222:", options: SearchOptions(), encoding: .utf8)
        let found = try #require(
            try ViewerSearch.find(
                pattern, in: source, content: document.content, from: 0, backwards: false, encoding: .utf8,
                chunkSize: 50_000))
        let row = try #require(try document.row(containing: found.lowerBound))
        #expect(row == 22_221)
        #expect(try document.rows(from: row, count: 1).first?.range.lowerBound == found.lowerBound)
    }

    // MARK: HTML and folders

    @Test func htmlBecomesTextWithItsLinks() {
        let html = """
            <html><head><title>Page</title><style>p { color: red }</style><script>alert("<b>")</script></head>
            <body><h1>Head&nbsp;line</h1><p>First   paragraph
            with a <a href="other.html">relative link</a> and an <A HREF='https://example.com/?a=1&amp;b=2'>absolute</A> one.</p>
            <!-- <p>hidden</p> --><ul><li>one &lt;1&gt;</li><li>two &#8364; &#x41;</li></ul><pre>  kept
              as is</pre></body></html>
            """
        let result = HTMLText.plainText(from: html)
        #expect(result.links == ["other.html", "https://example.com/?a=1&b=2"])
        #expect(
            result.text == """
                Page
                Head line
                First paragraph with a relative link {other.html} and an absolute {https://example.com/?a=1&b=2} one.
                one <1>
                two € A
                  kept
                  as is

                """)
        #expect(HTMLText.plainText(from: "<a href=x>y</a>", linkBraces: false).text == "y x\n")
        #expect(HTMLText.url(from: "{https://example.com/a}")?.absoluteString == "https://example.com/a")
        #expect(
            HTMLText.url(from: "www.example.com")?.absoluteString == "https://www.example.com"
                && HTMLText.url(from: "plain words") == nil)
    }

    @Test func folderSizesThatLeaveTheRangeOfANumberStopAtItsEnd() {
        let sum =
            FolderSummary(files: 1, folders: 0, bytes: .max - 1) + FolderSummary(files: 1, folders: 0, bytes: 10)
        #expect(sum == FolderSummary(files: 2, folders: 0, bytes: .max))
    }

    @Test func foldersAreSummedUpThroughTheirFileSystem() {
        let memory = MemoryFileSystem()
        memory.addFile("/top/a.txt", "12345")
        memory.addFile("/top/sub/b.txt", "123")
        memory.addFile("/top/sub/deep/c.txt", "1")
        memory.addDirectory("/top/empty")
        let summary = FolderSummary.measure(memory.url("/top"), provider: memory, cancellation: CancellationFlag())
        #expect(summary == FolderSummary(files: 3, folders: 3, bytes: 9))
        #expect(summary.text == "3 files, 3 folders, 9 bytes (9 b)")
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            FolderSummary.measure(memory.url("/top"), provider: memory, cancellation: cancelled) == FolderSummary())
    }
}
