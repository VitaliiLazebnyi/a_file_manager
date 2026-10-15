import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// The viewer's text: detection, decoding and HTML as text, in the cases the other tests leave out.
@Suite
internal struct CoverageViewerTextTests {
    private static let wrapped = ViewerLayout.text(TextLayoutOptions(columns: 80, wordWrap: true))

    // MARK: Detection

    /// Too little for UTF-16 is no UTF-16.
    @Test
    internal func twoBytesAreNotEnoughToTellUTF16() {
        #expect(ViewerDetection.guessUTF16([0x41, 0x00, 0x42]) == nil)
    }

    /// A replacement character in a short sample is a decoding failure; one that is in the
    /// bytes themselves proves nothing.
    @Test
    internal func replacementCharactersAreJudgedByTheBytes() {
        #expect(ViewerDetection.utf8Validity([0xFF, 0x41], mayBeCutOff: false) == .invalid)
        let mixed: [UInt8] = [0xFF, 0xEF, 0x41, 0xEF, 0xBF, 0x41, 0xEF, 0xBF, 0xBD]
        #expect(ViewerDetection.utf8Validity(mixed, mayBeCutOff: false) == .multiByte)
        #expect(ViewerDetection.utf8Validity([0xFF, 0xEF, 0x41, 0xEF, 0xBF, 0x41], mayBeCutOff: false) == .invalid)
    }

    /// "BM" is a bitmap only with its extension; a RIFF file is an image only when it is WebP.
    @Test
    internal func weakSignaturesNeedMoreThanTheirFirstBytes() {
        let bitmap = Data("BM".utf8) + Data(count: 30)
        #expect(ViewerDetection.content(name: "picture.bmp", sample: bitmap) == .image)
        #expect(ViewerDetection.content(name: "notes.txt", sample: bitmap) == .other)
        let webp = Data("RIFF".utf8) + Data(count: 4) + Data("WEBP".utf8)
        let wave = Data("RIFF".utf8) + Data(count: 4) + Data("WAVE".utf8)
        #expect(ViewerDetection.content(name: "photo", sample: webp) == .image)
        #expect(ViewerDetection.content(name: "sound", sample: wave) == .other)
    }

    /// The character sets an HTML head may name, and ones the viewer does not know.
    @Test
    internal func htmlCharsetsAreRecognised() {
        func charset(_ name: String) -> ViewerEncoding? {
            ViewerDetection.htmlCharset(Data("<meta charset=\"\(name)\">".utf8))
        }
        #expect(charset("utf-16") == .utf16LE && charset("UTF-16LE") == .utf16LE)
        #expect(charset("utf-16be") == .utf16BE)
        #expect(charset("iso-8859-1") == .latin1 && charset("latin1") == .latin1)
        #expect(charset("macintosh") == .macRoman)
        #expect(charset("windows-1251")?.codePage == 1_251)
        #expect(charset("koi8-u") == nil && charset("windows-x") == nil)
    }

    // MARK: Encodings

    /// A code page the system does not convert, or a number that is none, is not offered.
    @Test
    internal func unknownCodePagesAreNotOffered() {
        #expect(ViewerEncoding.codePage(-1) == nil)
        #expect(ViewerEncoding.codePage(12_345) == nil)
        #expect(ViewerEncoding.codePage(Int(UInt32.max) + 1) == nil)
        #expect(ViewerEncoding.utf8.isAvailable && ViewerEncoding.utf16BE.isAvailable)
        // A code page of one byte a character that the menu does not list is still offered by number.
        #expect(ViewerEncoding.codePage(28_592)?.name == "Code page 28592")
    }

    /// The byte layouts show text of more than one byte a character in ANSI.
    @Test
    internal func theByteLayoutsShowOneByteACharacter() {
        #expect(ViewerEncoding.utf8.forLayout(Self.wrapped) == .utf8)
        #expect(ViewerEncoding.utf8.forLayout(.hex) == .ansi)
        #expect(ViewerEncoding.dos.forLayout(.binary(width: 80)) == .dos)
    }

    /// An encoding the system does not know encodes nothing, and its table is that of Windows
    /// Latin 1.
    @Test
    internal func anEncodingTheSystemLacksFallsBackToLatin1() {
        let unknown = ViewerEncoding(codePage: 99_999, name: "Unknown")
        #expect(unknown.encode("a") == nil)
        let table = CodeTable.table(for: unknown)
        #expect(table.single[0xE9] == 0xE9 && table.single[0x80] == 0x20AC)
    }

    /// A lead byte at the very end, and an EUC-JP three-byte lead before something that is no
    /// trail byte.
    @Test
    internal func characterLengthsAtTheEdges() throws {
        let shiftJIS = CodeTable.table(for: try #require(ViewerEncoding.codePage(932)))
        let eucJP = CodeTable.table(for: try #require(ViewerEncoding.codePage(51_932)))
        let lead: [UInt8] = [0x41, 0x82]
        let length = lead.withUnsafeBufferPointer { shiftJIS.characterLength($0, at: 1) }
        #expect(length == 0)
        let stray: [UInt8] = [0x8F, 0x41]
        let strayLength = stray.withUnsafeBufferPointer { eucJP.characterLength($0, at: 0) }
        #expect(strayLength == 1)
    }

    /// Four-byte UTF-8 characters of the last planes are decoded as surrogate pairs.
    @Test
    internal func theLastPlanesOfUTF8AreDecoded() {
        var text = DecodedText()
        let used = ViewerEncoding.utf8.decode(
            [0xF4, 0x8F, 0xBF, 0xBF, 0xF1, 0x80, 0x80, 0x80],
            final: true,
            into: &text
        )
        #expect(used == 8)
        #expect(text.string == "\u{10FFFF}\u{40000}")
        #expect(text.offsets == [0, 0, 4, 4])
    }

    // MARK: HTML

    /// Only web addresses are links.
    @Test
    internal func onlyWebAddressesAreLinks() {
        #expect(HTMLText.url(from: "ftp://example.com/file") == nil)
        #expect(HTMLText.url(from: "www.example.com")?.absoluteString == "https://www.example.com")
    }

    /// Attribute names are found whatever their case.
    @Test
    internal func attributeNamesIgnoreCase() {
        #expect(HTMLText.attribute("HREF", in: "a Href=\"x.html\" title=y") == "x.html")
    }

    /// A script without its end tag, or whose end tag is cut off, hides the rest of the page.
    @Test
    internal func anUnclosedScriptHidesTheRest() {
        #expect(HTMLText.plainText(from: "<p>Before</p><script>var a = 1;").text == "Before\n")
        #expect(HTMLText.plainText(from: "<p>Before</p><script>x</script").text == "Before\n")
    }

    /// A tag name with letters beyond ASCII is no tag the viewer knows: only its text is kept.
    @Test
    internal func tagNamesBeyondASCIIAreUnknown() {
        #expect(HTMLText.plainText(from: "<aé>text</aé>").text == "text\n")
    }

    /// A link without braces is its text and its target, a space apart.
    @Test
    internal func aLinkWithoutBracesIsItsTarget() {
        let result = HTMLText.plainText(from: "<a href=\"https://a.example\">site</a> end", linkBraces: false)
        #expect(result.text == "site https://a.example end\n" && result.links == ["https://a.example"])
    }

    // MARK: Folders

    /// One file and one folder are counted in the singular.
    @Test
    internal func oneFileAndOneFolderAreSingular() {
        let summary = FolderSummary(files: 1, folders: 1, bytes: 10)
        #expect(summary.text.hasPrefix("1 file, 1 folder, 10 bytes"))
    }
}
