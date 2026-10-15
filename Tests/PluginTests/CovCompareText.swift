import AFMKernel
import Foundation
import Testing

@testable import CompareContentPlugin

/// Texts and their encodings, the parts of two lines that differ, lines with the same hash, and a binary comparison
/// that is cancelled.
@Suite
internal struct CovCompareText {
    /// The encodings are named, found by their byte-order marks, and write a text back the way they read it.
    @Test
    internal func encodingsAreNamedFoundAndWriteTheTextBack() {
        #expect(TextEncoding.utf8(bom: true).name == "UTF-8 (BOM)" && TextEncoding.utf8(bom: false).name == "UTF-8")
        #expect(TextEncoding.utf16LittleEndian.name == "UTF-16 LE" && TextEncoding.utf16BigEndian.name == "UTF-16 BE")
        #expect(TextEncoding.detect(Data([0xEF, 0xBB, 0xBF, 0x61])) == .utf8(bom: true))
        #expect(TextEncoding.detect(Data([0xFF, 0xFE, 0x61, 0x00])) == .utf16LittleEndian)
        #expect(TextEncoding.detect(Data([0xFE, 0xFF, 0x00, 0x61])) == .utf16BigEndian)
        #expect(TextEncoding.detect(Data("plain".utf8)) == .utf8(bom: false))
        #expect(TextEncoding.detect(Data([0x61, 0xFF])) == .latin1)
        for (bytes, encoding) in [
            ([0xEF, 0xBB, 0xBF, 0x61, 0x0A, 0x62], TextEncoding.utf8(bom: true)),
            ([0xFF, 0xFE, 0x61, 0x00, 0x0A, 0x00, 0x3D, 0xD8, 0x00, 0xDE], .utf16LittleEndian),
            ([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x0A, 0xD8, 0x3D, 0xDE, 0x00], .utf16BigEndian),
            ([0x61, 0xE9, 0x0D, 0x0A, 0x62], .latin1)
        ] as [([UInt8], TextEncoding)] {
            let document = TextDocument(data: Data(bytes))
            #expect(document.encoding == encoding && document.isLossless && document.data() == Data(bytes))
        }
    }

    /// A text read in a given encoding is taken as it is; UTF-16 with a lone surrogate still shows what can be read;
    /// a character
    /// Latin-1 does not have becomes a question mark.
    @Test
    internal func aGivenEncodingIsTakenAsItIs() {
        let given = TextDocument(data: Data([0x61, 0xE9]), encoding: .latin1)
        #expect(given.lines.map(\.text) == ["aé"] && given.isLossless)
        let broken = TextDocument(data: Data([0xFF, 0xFE, 0x00, 0xD8, 0x61, 0x00]), encoding: .utf16LittleEndian)
        #expect(broken.lines.first?.text.contains("a") == true)
        let latin = TextDocument(encoding: .latin1, lines: [TextLine("a€", ending: .none)])
        #expect(latin.data() == Data([0x61, 0x3F]))
    }

    /// A long stretch the two lines share at the end is not searched; the parts that differ are marked whole
    /// characters, marks and surrogate pairs included, beyond the part compared too.
    @Test
    internal func thePartsThatDifferAreWholeCharacters() {
        let shared = String(repeating: "s", count: 40)
        let (left, right) = TextDiff.inline("abc" + shared, "xyz" + shared)
        #expect(left == [0..<3] && right == [0..<3])
        // A changed mark is marked with its letter; two changes in one letter with its marks are one.
        let (marked, plain) = TextDiff.inline("e\u{301}e\u{301}x", "e\u{300}e\u{302}x")
        #expect(marked == [0..<4] && plain == [0..<4])
        let marks = "\u{302}\u{303}\u{304}"
        let (first, second) = TextDiff.inline("a\u{301}" + marks + "\u{305}", "a\u{300}" + marks + "\u{306}")
        #expect(first == [0..<6] && second == [0..<6])
        // A changed emoji is marked whole.
        let (smile, frown) = TextDiff.inline("a\u{1F600}b", "a\u{1F641}b")
        #expect(smile == [1..<3] && frown == [1..<3])
        // Past the part compared, a line that is longer is different there as well.
        let long = String(repeating: "\u{301}", count: TextDiff.inlineLimit + 10)
        let (beyond, short) = TextDiff.inline("a" + long, "b")
        #expect(beyond.last?.upperBound == TextDiff.inlineLimit + 11 && short == [0..<1])
    }

    /// Two different lines that happen to have the same hash are shown as changed, not as equal.
    @Test
    internal func linesWithTheSameHashAreComparedAgain() {
        let left = [TextLine("one"), TextLine("two")]
        let right = [TextLine("one"), TextLine("TWO!")]
        let diff = TextDiff.compute(
            left: left,
            right: right,
            options: DiffOptions(),
            anchors: [],
            costLimit: nil,
            cancellation: nil
        ) { lines in
            lines.map { _ in 7 }
        }
        #expect(diff.rows.map(\.kind) == [.equal, .changed] && diff.blocks == [1..<2])
    }

    /// A binary comparison that is cancelled stops before its first line.
    @Test
    internal func aCancelledBinaryComparisonStops() {
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let diff = BinaryDiff.compute(left: Data([1, 2, 3]), right: Data([1, 2, 4]), cancellation: cancellation)
        #expect(diff.differingBytes == 0 && diff.blocks.isEmpty && diff.rowCount == 1)
    }
}
