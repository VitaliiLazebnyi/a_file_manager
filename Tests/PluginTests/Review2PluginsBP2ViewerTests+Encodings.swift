import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// EUC-JP and GB 18030, revisited: offered, decoded with the offsets of their characters in pieces
/// and whole, their character boundaries exact, searched and shown in rows.
extension Review2PluginsBP2ViewerTests {
    /// The characters one by one: their bytes, so the start of every character is known without the decoder.
    private func encode(_ characters: [String], _ encoding: ViewerEncoding) throws -> (data: Data, starts: [Int]) {
        var data = Data()
        var starts: [Int] = []
        for character in characters {
            starts.append(data.count)
            data.append(contentsOf: try encoding.encode(character))
        }
        return (data, starts)
    }

    /// Where the viewer's search finds `needle` in `data`, from the start forwards or from the end backwards, read in
    /// chunks of `chunk` bytes.
    private func find(
        _ needle: String,
        in data: Data,
        _ encoding: ViewerEncoding,
        backwards: Bool,
        chunk: Int
    ) throws -> Range<Int64>? {
        var options = SearchOptions()
        options.backwards = backwards
        var tuning = ViewerSearch.Tuning.standard
        tuning.chunkSize = chunk
        return try ViewerSearch.find(
            ViewerSearch.Request(
                pattern: try SearchPattern(needle, options: options, encoding: encoding),
                start: backwards ? Int64(data.count) : 0,
                backwards: backwards
            ),
            in: ViewerSearch.Subject(
                source: DataByteSource(data),
                content: 0..<Int64(data.count),
                encoding: encoding,
                boundaries: nil
            ),
            tuning: tuning,
            cancellation: CancellationFlag()
        ) { _ in
            // Not watched here.
        }
    }

    /// EUC-JP and GB 18030 are offered as double-byte code pages of their own shape; ISO-2022 is not.
    @Test
    internal func eucJPAndGB18030AreOffered() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb18030 = try #require(ViewerEncoding.codePage(54_936))
        #expect(
            euc.kind == .doubleByte && euc.shape == .eucJP && gb18030.kind == .doubleByte && gb18030.shape == .gb18030
        )
        #expect(euc.isAvailable && gb18030.isAvailable)
        let offered = ViewerEncoding.codePages.map(\.codePage)
        #expect(offered.contains(51_932) && offered.contains(54_936))
        #expect(!euc.byteOriented.isUnicode && euc.byteOriented == .ansi)
        // Another code page of many bytes is still not offered.
        #expect(ViewerEncoding.codePage(50_220) == nil)
    }

    /// EUC-JP is decoded with the offset of every character; a JIS X 0212 character and stray bytes
    /// become replacements.
    @Test
    internal func eucJPTextIsDecodedWithItsOffsets() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let characters = ["日", "本", "語", "a", "ｱ", "ｲ", "テ", "キ", "ス", "ト", "、", " ", "b", "\n", "漢", "字"]
        let (data, starts) = try encode(characters, euc)
        let lastStart = try #require(starts.last)
        #expect(data.count == lastStart + 2)
        var decoded = DecodedText()
        let used = euc.decode(data, final: true, into: &decoded)
        #expect(used == data.count && decoded.string == characters.joined())
        #expect(decoded.offsets.map(Int.init) == starts)
        // A character of JIS X 0212 (three bytes: 0x8F and two more) is one character, shown as a replacement.
        var rare = DecodedText()
        euc.decode(Data([0x41, 0x8F, 0xB0, 0xA1, 0x42]), final: true, into: &rare)
        #expect(rare.units == [0x41, 0xFFFD, 0x42] && rare.offsets == [0, 1, 4])
        // Bytes that fit no character: one replacement each, and the next byte keeps its own meaning.
        var stray = DecodedText()
        euc.decode(Data([0xA4, 0x41, 0x8E, 0x41, 0xFF, 0x8F, 0xA1, 0x42]), final: true, into: &stray)
        #expect(stray.units == [0xFFFD, 0x41, 0xFFFD, 0x41, 0xFFFD, 0xFFFD, 0xFFFD, 0x42])
    }

    /// GB 18030 is decoded with the offset of every character, beyond the Basic Multilingual Plane too;
    /// broken four-byte sequences become replacements.
    @Test
    internal func gb18030TextIsDecodedWithItsOffsets() throws {
        let gb18030 = try #require(ViewerEncoding.codePage(54_936))
        // Two-byte characters, ASCII, four-byte ones in and beyond the Basic Multilingual Plane.
        let characters = ["中", "文", "a", "1", "\u{80}", "\u{FFFF}", "\u{20000}", "😀", "€", "龙", "9", "\n", "b"]
        let (data, starts) = try encode(characters, gb18030)
        var decoded = DecodedText()
        let used = gb18030.decode(data, final: true, into: &decoded)
        #expect(used == data.count)
        #expect(decoded.string == characters.joined())
        // The two halves of a character beyond the plane share their offset.
        var expected: [Int] = []
        for (character, start) in zip(characters, starts) {
            expected += Array(repeating: start, count: character.utf16.count)
        }
        #expect(decoded.offsets.map(Int.init) == expected)
        // Four-byte structure that does not hold up: stray bytes, and what follows keeps its own meaning
        // (0x8141 is a pair).
        var stray = DecodedText()
        gb18030.decode(Data([0x81, 0x30, 0x41, 0x81, 0x30, 0x81, 0x41, 0x81, 0x7F, 0xFF]), final: true, into: &stray)
        #expect(stray.units == [0xFFFD, 0x30, 0x41, 0xFFFD, 0x30, 0x4E04, 0xFFFD, 0x7F, 0xFFFD])
    }

    /// Text decoded in pieces of any size gives the units and offsets of the text decoded whole.
    @Test
    internal func textDecodedInPiecesEqualsTextDecodedWhole() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb18030 = try #require(ViewerEncoding.codePage(54_936))
        let eucData =
            try encode(["日", "本", "a", "ｱ", "語", "\n", "テ", "ス", "ト", "漢"], euc).data
            + Data([0x8F, 0xB0, 0xA1, 0x41, 0x8E])
        let gbData =
            try encode(["中", "\u{80}", "a", "😀", "文", "\n", "龙", "9", "\u{FFFF}", "€"], gb18030).data
            + Data([0x81, 0x30, 0x81])
        for (encoding, data) in [(euc, eucData), (gb18030, gbData)] {
            var whole = DecodedText()
            encoding.decode(data, final: true, into: &whole)
            for cut in 1...9 {
                var units: [UInt16] = []
                var offsets: [Int] = []
                var position = 0
                var piece = DecodedText()
                while position < data.count {
                    var end = min(data.count, position + cut)
                    var took = 0
                    while true {
                        let final = end == data.count
                        took = encoding.decode(Array(data[position..<end]), final: final, into: &piece)
                        if took > 0 || final { break }
                        end = min(data.count, end + 1)
                    }
                    units += piece.units
                    offsets += piece.offsets.map { Int($0) + position }
                    position += took
                    if took == 0 { break }
                }
                #expect(units == whole.units && offsets == whole.offsets.map(Int.init), "\(encoding.name) cut \(cut)")
            }
        }
    }

    /// The start of the character at any offset is found exactly in long runs of EUC-JP and GB 18030,
    /// whatever the spacing of the remembered boundaries.
    @Test
    internal func characterBoundariesAreExactInEUCJPAndGB18030() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb18030 = try #require(ViewerEncoding.codePage(54_936))
        // Long runs without a byte that stands by itself: the boundary cannot be guessed from the neighbours.
        let kanji = (0..<400).map { ["日", "本", "語", "漢", "字", "龍"][$0 % 6] }
        let rareGB = (0..<400).map { ["\u{20000}", "龙", "\u{80}", "文", "😀", "中"][$0 % 6] }
        let mixedGB = (0..<400).map { ["\u{20000}", "龙", "1", "文", "9", "中", "a", "\u{FFFF}"][$0 % 8] }
        let mixedEUC = (0..<400).map { ["日", "ｱ", "a", "本", "ｲ", "語", "\n", "字"][$0 % 8] }
        for (encoding, characters) in [(euc, kanji), (gb18030, rareGB), (gb18030, mixedGB), (euc, mixedEUC)] {
            let (data, starts) = try encode(characters, encoding)
            for spacing in [16, 17, 50, 1 << 14] {
                let boundaries = CharacterBoundaries(
                    source: DataByteSource(data),
                    content: 0..<Int64(data.count),
                    encoding: encoding,
                    spacing: spacing
                )
                var expected = 0
                for offset in stride(from: data.count - 1, through: 0, by: -3) {
                    while expected + 1 < starts.count, starts[expected + 1] <= offset { expected += 1 }
                    // Walk back to the character offset is in.
                    let want = try #require(starts.last { $0 <= offset })
                    #expect(
                        try boundaries.characterStart(atOrBefore: Int64(offset), cancellation: nil) == Int64(want),
                        "\(encoding.name) spacing \(spacing) offset \(offset)"
                    )
                }
            }
        }
    }

    /// A search in EUC-JP and GB 18030, forwards and backwards, finds only whole characters, whatever
    /// the chunk size.
    @Test
    internal func aSearchInEUCJPAndGB18030FindsWholeCharactersWhateverTheChunkSize() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb18030 = try #require(ViewerEncoding.codePage(54_936))
        for (encoding, characters, needle) in [
            (
                euc, (0..<300).map { ["日", "本", "語", "漢", "字"][$0 % 5] } + ["龍", "亀"] + (0..<20).map { _ in "日" }, "龍亀"
            ),
            (
                gb18030,
                (0..<300).map { ["\u{20000}", "龙", "\u{80}", "文"][$0 % 4] } + ["龙", "亀"] + (0..<20).map { _ in "文" },
                "龙亀"
            )
        ] {
            let (data, starts) = try encode(characters, encoding)
            let want = Int64(starts[300])..<Int64(starts[302])
            for chunk in [3, 7, 16, 61, 4_096] {
                let found = try find(needle, in: data, encoding, backwards: false, chunk: chunk)
                #expect(found == want, "\(encoding.name) chunk \(chunk)")
                let last = try find(needle, in: data, encoding, backwards: true, chunk: chunk)
                #expect(last == want, "\(encoding.name) backwards chunk \(chunk)")
            }
        }
    }

    /// A document in GB 18030 or EUC-JP, indexed in tiny segments and chunks, shows its lines as rows.
    @Test
    internal func aTextDocumentInGB18030AndEUCJPShowsItsRows() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb18030 = try #require(ViewerEncoding.codePage(54_936))
        let eucText = "日本語のテキスト\nｱｲｳ abc\n漢字\n"
        let gbText = "中文 \u{20000} 文本\n€ 龙\n"
        for (encoding, text) in [(euc, eucText), (gb18030, gbText)] {
            let data = try encoding.encode(text)
            let indexing = Indexing(encoding: encoding, segment: 7, chunk: 5)
            let shown = try rows(indexing.document(Data(data), columns: 80))
            #expect(shown == text.split(separator: "\n").map(String.init), "\(encoding.name)")
        }
    }
}
