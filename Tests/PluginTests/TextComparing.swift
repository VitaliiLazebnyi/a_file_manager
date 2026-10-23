import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Two texts laid side by side: encodings, line breaks, rows, options and the parts that differ inside a line.
@Suite
internal struct TextComparing {
    /// A sample file: its bytes, the encoding it is read in, and the texts of its lines.
    private struct Sample {
        /// The bytes of the file.
        let data: Data
        /// The encoding they are found to be in.
        let encoding: TextEncoding
        /// The texts of the lines.
        let texts: [String]
    }

    /// The lines of a text.
    internal func lines(_ text: String) -> [TextLine] { TextDocument.split(text) }

    /// The kinds of the rows of two texts by the usual options: `=` equal, `~` changed, `+` added, `-` removed.
    internal func kinds(_ left: String, _ right: String) -> String {
        kinds(left, right, DiffOptions())
    }

    /// The kinds of the rows of two texts by `options`: `=` equal, `~` changed, `+` added, `-` removed.
    internal func kinds(_ left: String, _ right: String, _ options: DiffOptions) -> String {
        TextDiff.compute(left: lines(left), right: lines(right), options: options).rows
            .map { row in
                switch row.kind {
                case .equal:
                    return "="

                case .changed:
                    return "~"

                case .added:
                    return "+"

                case .removed:
                    return "-"
                }
            }
            .joined()
    }

    /// Encodings are detected, and the bytes are written back unchanged.
    @Test
    internal func encodingsAreDetectedAndWrittenBackUnchanged() {
        let samples = [
            Sample(data: Data("grüße\nwelt\n".utf8), encoding: .utf8(bom: false), texts: ["grüße", "welt"]),
            Sample(data: Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb".utf8), encoding: .utf8(bom: true), texts: ["a", "b"]),
            Sample(
                data: Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00, 0x0A, 0x00, 0xE4, 0x00]),
                encoding: .utf16LittleEndian,
                texts: ["hi", "ä"]
            ),
            Sample(
                data: Data([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69, 0x00, 0x0D, 0x00, 0x6A]),
                encoding: .utf16BigEndian,
                texts: ["hi", "j"]
            ),
            Sample(data: Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF]), encoding: .latin1, texts: ["café", "ÿ"]),
            Sample(data: Data(), encoding: .utf8(bom: false), texts: [])
        ]
        for sample in samples {
            let document = TextDocument(data: sample.data)
            #expect(document.encoding == sample.encoding)
            #expect(document.lines.map(\.text) == sample.texts)
            #expect(document.data() == sample.data, "\(sample.encoding.name)")
        }
        #expect(TextEncoding.utf16LittleEndian.name == "UTF-16 LE" && TextEncoding.latin1.name == "Latin-1")
    }

    /// Lines keep their own line breaks; a line put after the last gets the usual one.
    @Test
    internal func linesKeepTheirOwnLineBreaks() {
        let document = TextDocument(data: Data("one\ntwo\r\nthree\rfour\n\nlast".utf8))
        #expect(document.lines.map(\.text) == ["one", "two", "three", "four", "", "last"])
        #expect(
            document.lines.map(\.ending) == [
                .lineFeed, .carriageReturnLineFeed, .carriageReturn, .lineFeed, .lineFeed, .noBreak
            ]
        )
        #expect(document.lines.map(\.number) == [1, 2, 3, 4, 5, 6] && document.usualEnding == .lineFeed)
        #expect(
            TextDocument.split("\n").map(\.text) == [""] && TextDocument.split("").isEmpty
                && TextDocument.split("a\r").map(\.ending) == [.carriageReturn]
        )

        // A line put after a last line without a break gets the file's usual break.
        var windows = TextDocument(data: Data("a\r\nb\r\nc".utf8))
        windows.lines.append(TextLine("d", ending: .noBreak))
        #expect(String(bytes: windows.data(), encoding: .utf8) == "a\r\nb\r\nc\r\nd")
    }

    /// Files with a zero byte near the start are binary; UTF-16 with its mark is not.
    @Test
    internal func binaryFilesAreRecognised() {
        #expect(TextDocument.looksBinary(Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01])))
        #expect(!TextDocument.looksBinary(Data("plain text".utf8)) && !TextDocument.looksBinary(Data()))
        #expect(!TextDocument.looksBinary(Data([0xFF, 0xFE, 0x68, 0x00])))
    }

    /// The rows show changed, added and removed lines; a run of them is one difference.
    @Test
    internal func rowsShowChangedAddedAndRemovedLines() {
        #expect(kinds("a\nb\nc\n", "a\nb\nc\n") == "===")
        #expect(kinds("a\nb\nc\n", "a\nx\nc\n") == "=~=")
        #expect(kinds("a\nc\n", "a\nb\nc\n") == "=+=")
        #expect(kinds("a\nb\nc\n", "a\nc\n") == "=-=")
        #expect(kinds("a\nb\nc\nd\n", "a\nx\nd\n") == "=~-=")
        #expect(kinds("a\nb\nd\n", "a\nx\ny\nz\nd\n") == "=~++=")
        #expect(kinds("", "a\nb\n") == "++" && kinds("a\n", "") == "-" && kinds("", "").isEmpty)

        let diff = TextDiff.compute(left: lines("a\nb\nc\nd\ne\nf\n"), right: lines("a\nX\nY\nd\ne\nf\ng\n"))
        // A run of differing rows is one difference.
        #expect(diff.blocks == [1..<3, 6..<7] && !diff.isIdentical)
        #expect(
            diff.rows[1] == DiffRow(left: 1, right: 1, kind: .changed)
                && diff.rows[6] == DiffRow(left: nil, right: 6, kind: .added)
        )
    }

    /// The options decide which lines are equal.
    @Test
    internal func optionsDecideWhichLinesAreEqual() {
        let exact = DiffOptions(ignoreCase: false, ignoreRepeatedSpaces: false, ignoreLineEndings: false)
        #expect(kinds("Hello\n", "hello\n") == "=" && kinds("Hello\n", "hello\n", exact) == "~")
        #expect(kinds("  a   b\t c  \n", "a b c\n") == "=" && kinds("  a   b\t c  \n", "a b c\n", exact) == "~")
        #expect(kinds("ab\n", "a b\n") == "~")
        #expect(kinds("a\r\nb\r\n", "a\nb\n") == "==" && kinds("a\r\nb\n", "a\nb\n", exact) == "~=")
        #expect(kinds("a\nb", "a\nb\n") == "==" && kinds("a\nb", "a\nb\n", exact) == "=~")
        #expect(kinds("A  b\n", "a b\n", DiffOptions(ignoreCase: true, ignoreRepeatedSpaces: false)) == "~")
        #expect(kinds("ÄÖ\n", "äö\n") == "=")
        #expect(DiffOptions().key(TextLine("\t Mixed   CASE ")) == "mixed case")
        #expect(exact.key(TextLine(" x ", ending: .carriageReturnLineFeed)) == " x \r\n")
    }

    /// The rows always rebuild the right file, for any texts and options.
    @Test
    internal func theRowsAlwaysRebuildTheRightFile() throws {
        var random = DiffChecks.Seeded(state: 11)
        let words = ["alpha", "Alpha", "beta", " beta", "gamma  delta", "gamma delta", "", "end", "END", "x"]
        for round in 0..<300 {
            let left = (0..<Int.random(in: 0...30, using: &random))
                .map { _ in
                    TextLine(words[Int.random(in: 0..<words.count, using: &random)])
                }
            let right = (0..<Int.random(in: 0...30, using: &random))
                .map { _ in
                    TextLine(words[Int.random(in: 0..<words.count, using: &random)])
                }
            let options = DiffOptions(
                ignoreCase: round.isMultiple(of: 2),
                ignoreRepeatedSpaces: round.isMultiple(of: 3)
            )
            let diff = TextDiff.compute(left: left, right: right, options: options)
            #expect(diff.rebuiltRight(left: left, right: right) == right)
            #expect(
                diff.rows.compactMap(\.left) == Array(left.indices)
                    && diff.rows.compactMap(\.right) == Array(right.indices)
            )
            for row in diff.rows where row.kind == .equal {
                let (leftIndex, rightIndex) = (try #require(row.left), try #require(row.right))
                #expect(options.key(left[leftIndex]) == options.key(right[rightIndex]))
            }
            #expect(diff.blocks.reduce(0) { $0 + $1.count } == diff.rows.filter { $0.kind != .equal }.count)
        }
    }

    /// Long texts are keyed on all cores and compared correctly.
    @Test
    internal func longTextsAreKeyedOnAllCores() {
        let left = (0..<60_000).map { TextLine("Line   NUMBER \($0)") }
        var right = left.map { TextLine($0.text.lowercased().replacingOccurrences(of: "   ", with: " ")) }
        right[30_000].text = "different"
        right.remove(at: 5)
        let diff = TextDiff.compute(left: left, right: right)
        #expect(diff.blocks == [5..<6, 30_000..<30_001])
        #expect(diff.rebuiltRight(left: left, right: right) == right)
    }

    /// Resync anchors force two lines together; odd anchors are changed rows or ignored.
    @Test
    internal func resyncAnchorsForceLinesTogether() {
        let left = lines("start\nrepeat\nrepeat\nleft only\nend\n")
        let right = lines("start\nrepeat\nright only\nrepeat\nend\n")
        let free = TextDiff.compute(left: left, right: right)
        #expect(free.rows.contains(DiffRow(left: 1, right: 1, kind: .equal)))
        // The user says the second "repeat" on the left is the first one on the right.
        let anchored = TextDiff.compute(left: left, right: right, anchors: [(left: 2, right: 1)])
        #expect(
            anchored.rows.contains(DiffRow(left: 2, right: 1, kind: .equal))
                && !anchored.rows.contains(DiffRow(left: 1, right: 1, kind: .equal))
        )
        #expect(anchored.rebuiltRight(left: left, right: right) == right)
        // An anchor on lines that differ is a changed row; anchors out of range are ignored.
        let odd = TextDiff.compute(left: left, right: right, anchors: [(left: 3, right: 2), (left: 99, right: 0)])
        #expect(
            odd.rows.contains(DiffRow(left: 3, right: 2, kind: .changed))
                && odd.rebuiltRight(left: left, right: right) == right
        )
    }

    /// The parts that differ inside a line, whole words and not stray letters.
    @Test
    internal func differencesInsideALine() {
        func marked(_ left: String, _ right: String) -> [String] {
            let ranges = TextDiff.inline(left, right)
            func cut(_ text: String, _ ranges: [Range<Int>]) -> String {
                ranges.map { String(decoding: Array(text.utf16)[$0], as: UTF16.self) }.joined(separator: "|")
            }
            return [cut(left, ranges.left), cut(right, ranges.right)]
        }
        #expect(marked("the fox jumps over", "the fox jumped over") == ["s", "ed"])
        #expect(marked("same", "same") == ["", ""])
        #expect(marked("", "new") == ["", "new"])
        #expect(marked("value = 10;", "value = 25;") == ["10", "25"])
        // One stray common letter does not split a changed word.
        #expect(marked("call(alpha)", "call(omega)") == ["alpha", "omega"])
        #expect(marked("first and last", "FIRST and LAST") == ["first|last", "FIRST|LAST"])
        // Beyond the limit the rest counts as one difference.
        let long = String(repeating: "a", count: TextDiff.inlineLimit + 10)
        let ranges = TextDiff.inline(long, long + "b")
        #expect(
            ranges.left == [TextDiff.inlineLimit..<(TextDiff.inlineLimit + 10)]
                && ranges.right == [TextDiff.inlineLimit..<(TextDiff.inlineLimit + 11)]
        )
    }
}
