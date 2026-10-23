import Foundation
import Testing

@testable import ViewerPlugin

/// The viewer's logic without any window: detection of contents and encodings, and decoding block by block.
@Suite
internal struct ViewerModelTests {
    /// Decodes `data` in pieces of `size` bytes, carrying what a piece leaves undecoded into
    /// the next, and returns the units with their offsets in the whole.
    private func decodeInPieces(_ data: [UInt8], _ encoding: ViewerEncoding, size: Int) -> (
        units: [UInt16], offsets: [Int]
    ) {
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

    // MARK: Detection

    /// A byte order mark names the encoding and its length.
    @Test
    internal func byteOrderMarksNameTheEncoding() {
        #expect(
            ViewerDetection.guessText(Data([0xEF, 0xBB, 0xBF, 0x41]), isWholeFile: true)
                == .init(encoding: .utf8, bomLength: 3)
        )
        #expect(
            ViewerDetection.guessText(Data([0xFF, 0xFE, 0x41, 0x00]), isWholeFile: true)
                == .init(encoding: .utf16LE, bomLength: 2)
        )
        #expect(
            ViewerDetection.guessText(Data([0xFE, 0xFF, 0x00, 0x41]), isWholeFile: true)
                == .init(encoding: .utf16BE, bomLength: 2)
        )
    }

    /// Without a mark the encoding is guessed from the bytes: UTF-8, UTF-16 of either order, Windows, DOS, or binary.
    @Test
    internal func textEncodingsAreGuessedFromTheContent() throws {
        func guess(_ bytes: [UInt8], whole: Bool = true) -> ViewerDetection.TextGuess {
            ViewerDetection.guessText(Data(bytes), isWholeFile: whole)
        }
        #expect(guess(Array("plain text\r\n".utf8)).encoding == .utf8)
        #expect(guess(Array("Größe 5 €".utf8)).encoding == .utf8)
        // A sample cut off in the middle of a character is still UTF-8; a whole file is not.
        let cut = Array(Array("Größe €".utf8).dropLast())
        #expect(guess(cut, whole: false).encoding == .utf8)
        #expect(guess(cut, whole: true).encoding != .utf8)
        let little = try ViewerEncoding.utf16LE.encode("Hello, world\r\n")
        let big = try ViewerEncoding.utf16BE.encode("Hello, world\r\n")
        #expect(guess(little).encoding == .utf16LE)
        #expect(guess(big).encoding == .utf16BE)
        // Windows: accented letters inside words. DOS: frames, and letters where Windows has none.
        let ansi = try ViewerEncoding.ansi.encode("Größe und Maße, déjà vu")
        #expect(guess(ansi) == .init(encoding: .ansi))
        let dos = try ViewerEncoding.dos.encode("╔════════╗\r\n║ Gr\u{F6}\u{DF}e  ║\r\n╚════════╝")
        #expect(guess(dos) == .init(encoding: .dos))
        #expect(guess([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04]).isBinary)
        #expect(guess([0x01, 0x02, 0x03, 0x04, 0x41, 0x05, 0x06, 0x07]).isBinary)
        #expect(!guess(Array("tab\tand\u{1B}[0m escape".utf8)).isBinary)
        #expect(guess([]).encoding == .utf8)
    }

    /// The kind of content comes from the name and the first bytes, with extra media extensions, vetoes and an HTML
    /// charset.
    @Test
    internal func contentKindsComeFromNameAndFirstBytes() {
        func kind(_ name: String, _ head: [UInt8] = []) -> ViewerDetection.Content {
            ViewerDetection.content(name: name, sample: Data(head), additionalMedia: [], vetoed: [])
        }
        #expect(
            kind("a.PNG") == .image && kind("noext", [0x89, 0x50, 0x4E, 0x47]) == .image
                && kind("x.dat", [0xFF, 0xD8, 0xFF, 0xE0]) == .image
        )
        #expect(kind("song.mp3") == .media && kind("clip.MOV") == .media)
        #expect(kind("doc.bin", Array("%PDF-1.7".utf8)) == .pdf && kind("x.txt", Array("{\\rtf1\\ansi".utf8)) == .rtf)
        #expect(kind("index.htm") == .html && kind("page", Array("  <!DOCTYPE html><html>".utf8)) == .html)
        #expect(kind("notes.txt", Array("hello".utf8)) == .other)
        #expect(
            ViewerDetection.content(
                name: "a.mkv",
                sample: Data(),
                additionalMedia: ViewerDetection.extensions(in: "*.mkv *.wmv"),
                vetoed: []
            )
                == .media
        )
        #expect(
            ViewerDetection.content(
                name: "a.jpg",
                sample: Data([0xFF, 0xD8, 0xFF]),
                additionalMedia: [],
                vetoed: ["jpg"]
            )
                == .other
        )
        #expect(
            ViewerDetection.htmlCharset(
                Data("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1251\">".utf8)
            )?
            .codePage
                == 1_251
        )
        #expect(ViewerDetection.htmlCharset(Data("<meta charset='UTF-8'>".utf8)) == .utf8)
    }

    // MARK: Decoding

    /// Decoding in pieces of any size gives the units and offsets of decoding at once, in every kind of encoding.
    @Test
    internal func decodingBlockByBlockEqualsDecodingAtOnce() throws {
        let sample = "ASCII, Größe, 日本語のテキスト, emoji 😀🎉, tab\tend\r\n"
        let cases: [(ViewerEncoding, [UInt8])] = [
            (.utf8, Array(sample.utf8)), (.utf16LE, try ViewerEncoding.utf16LE.encode(sample)),
            (.utf16BE, try ViewerEncoding.utf16BE.encode(sample)),
            (
                try #require(ViewerEncoding.codePage(932)),
                try #require(ViewerEncoding.codePage(932)).encode("ABC 日本語のテキスト xyz ｶﾀｶﾅ")
            ),
            (.ansi, try ViewerEncoding.ansi.encode("Größe € déjà")),
            (.dos, try ViewerEncoding.dos.encode("╔═╗ Größe"))
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

    /// A character cut off at the end of a block waits for its rest, unless the block is the last.
    @Test
    internal func aCharacterCutOffAtTheEndWaitsForItsRest() {
        var text = DecodedText()
        let euro: [UInt8] = [0x41, 0xE2, 0x82]
        #expect(ViewerEncoding.utf8.decode(euro, final: false, into: &text) == 1 && text.units == [0x41])
        #expect(
            ViewerEncoding.utf8.decode(euro, final: true, into: &text) == 3 && text.units == [0x41, 0xFFFD, 0xFFFD]
        )
        // Half a surrogate pair, and half a code unit.
        #expect(ViewerEncoding.utf16LE.decode([0x41, 0x00, 0x3D, 0xD8], final: false, into: &text) == 2)
        #expect(ViewerEncoding.utf16LE.decode([0x41, 0x00, 0x42], final: false, into: &text) == 2)
        #expect(
            ViewerEncoding.utf16LE.decode([0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE], final: false, into: &text) == 6
                && text.string == "A😀"
        )
        #expect(text.offsets == [0, 2, 2])
    }

    /// Malformed bytes become replacement characters, each keeping its offset, and a stray lead byte keeps the line
    /// end.
    @Test
    internal func malformedInputBecomesReplacementCharactersAndKeepsItsOffsets() {
        var text = DecodedText()
        // An overlong form, a lone continuation byte, a surrogate, a value beyond U+10FFFF.
        let bytes: [UInt8] = [0x41, 0xC0, 0x80, 0x80, 0xED, 0xA0, 0x80, 0xF5, 0x42]
        #expect(ViewerEncoding.utf8.decode(bytes, final: true, into: &text) == bytes.count)
        #expect(
            text.units.first == 0x41 && text.units.last == 0x42
                && text.units.dropFirst().dropLast().allSatisfy { $0 == 0xFFFD }
        )
        #expect(text.offsets == [0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(
            ViewerEncoding.utf16LE.decode([0x00, 0xDC, 0x41, 0x00], final: true, into: &text) == 4
                && text.units == [0xFFFD, 0x41]
        )
        // A lead byte of a double-byte page before a line end does not swallow the line end.
        let japanese = ViewerEncoding.codePage(932)
        #expect(
            japanese?.decode([0x83, 0x0A, 0x41], final: true, into: &text) == 3 && text.units == [0xFFFD, 0x0A, 0x41]
        )
    }
}
