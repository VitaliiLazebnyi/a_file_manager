import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Random numbers that are the same in every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

/// The length of the longest common subsequence, by the textbook table.
private func longestCommon<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    var row = [Int](repeating: 0, count: b.count + 1)
    for x in a {
        var diagonal = 0
        for (index, y) in b.enumerated() {
            let above = row[index + 1]
            row[index + 1] = x == y ? diagonal + 1 : max(above, row[index])
            diagonal = above
        }
    }
    return row[b.count]
}

/// What every diff must be, whatever it was computed with: a cover of both sequences in
/// order, with equal stretches that are equal, turning `a` into `b`.
private func isValid<T: Hashable>(_ segments: [DiffSegment], _ a: [T], _ b: [T]) -> Bool {
    var (i, j) = (0, 0)
    for segment in segments {
        guard segment.a.lowerBound == i, segment.b.lowerBound == j, !(segment.a.isEmpty && segment.b.isEmpty) else {
            return false
        }
        if segment.isEqual, Array(a[segment.a]) != Array(b[segment.b]) { return false }
        (i, j) = (segment.a.upperBound, segment.b.upperBound)
    }
    return i == a.count && j == b.count && Myers.apply(segments, to: a, from: b) == b
}

@Suite struct MyersDiff {
    @Test func edgeCases() {
        #expect(Myers.diff([Int](), []) == [])
        #expect(Myers.diff([], [1, 2]) == [DiffSegment(a: 0..<0, b: 0..<2, isEqual: false)])
        #expect(Myers.diff([1, 2], []) == [DiffSegment(a: 0..<2, b: 0..<0, isEqual: false)])
        #expect(Myers.diff([1, 2, 3], [1, 2, 3]) == [DiffSegment(a: 0..<3, b: 0..<3, isEqual: true)])
        #expect(Myers.diff([1], [2]) == [DiffSegment(a: 0..<1, b: 0..<1, isEqual: false)])
        #expect(Myers.diff([1, 2, 3], [4, 5]) == [DiffSegment(a: 0..<3, b: 0..<2, isEqual: false)])
        #expect(
            Myers.diff(Array("abcd"), Array("abXcd")) == [
                DiffSegment(a: 0..<2, b: 0..<2, isEqual: true), DiffSegment(a: 2..<2, b: 2..<3, isEqual: false),
                DiffSegment(a: 2..<4, b: 3..<5, isEqual: true)
            ]
        )
        #expect(
            Myers.diff(Array("abcd"), Array("ad")) == [
                DiffSegment(a: 0..<1, b: 0..<1, isEqual: true), DiffSegment(a: 1..<3, b: 1..<1, isEqual: false),
                DiffSegment(a: 3..<4, b: 1..<2, isEqual: true)
            ]
        )
        // The classic example of the paper: five edits.
        #expect(Myers.editDistance(Myers.diff(Array("ABCABBA"), Array("CBABAC"))) == 5)
    }

    @Test func applyingTheDiffToAYieldsBAndItIsTheShortest() {
        var random = Seeded(state: 42)
        for round in 0..<600 {
            let alphabet = [2, 3, 5, 12][round % 4]
            let a = (0..<Int.random(in: 0...40, using: &random))
                .map { _ in
                    Int.random(in: 0..<alphabet, using: &random)
                }
            let b = (0..<Int.random(in: 0...40, using: &random))
                .map { _ in
                    Int.random(in: 0..<alphabet, using: &random)
                }
            let segments = Myers.diff(a, b)
            #expect(isValid(segments, a, b), "\(a) -> \(b)")
            #expect(Myers.editDistance(segments) == a.count + b.count - 2 * longestCommon(a, b), "\(a) -> \(b)")
        }
    }

    @Test func editedCopiesAreFoundExactly() {
        var random = Seeded(state: 7)
        for _ in 0..<40 {
            let a = (0..<Int.random(in: 50...400, using: &random)).map { _ in Int.random(in: 0..<60, using: &random) }
            var b = a
            for _ in 0..<Int.random(in: 0...12, using: &random) {
                let position = Int.random(in: 0...b.count, using: &random)
                if Bool.random(using: &random), position < b.count {
                    b.remove(at: position)
                } else {
                    b.insert(Int.random(in: 0..<70, using: &random), at: position)
                }
            }
            let segments = Myers.diff(a, b)
            #expect(isValid(segments, a, b))
            #expect(Myers.editDistance(segments) == a.count + b.count - 2 * longestCommon(a, b))
        }
    }

    @Test func aBoundedSearchStillGivesACorrectDiff() {
        var random = Seeded(state: 99)
        for limit in [1, 2, 5] {
            for _ in 0..<150 {
                let a = (0..<Int.random(in: 0...120, using: &random)).map { _ in Int.random(in: 0..<6, using: &random) }
                let b = (0..<Int.random(in: 0...120, using: &random)).map { _ in Int.random(in: 0..<6, using: &random) }
                let segments = Myers.diff(a, b, costLimit: limit)
                #expect(isValid(segments, a, b))
                #expect(Myers.editDistance(segments) >= a.count + b.count - 2 * longestCommon(a, b))
            }
        }
    }

    @Test func hugeInputsFallBackToTheHeuristicAndStayCorrect() {
        // Two long texts in different order: far more differences than an exact search could
        // go through, and more elements than `exactBelow`.
        var random = Seeded(state: 3)
        let a = (0..<30_000).map { _ in Int.random(in: 0..<400, using: &random) }
        let b = (0..<30_000).map { _ in Int.random(in: 0..<400, using: &random) }
        #expect(a.count + b.count > Myers.exactBelow)
        // The work done is bounded by the cost limit, not by the clock: the time of this thread's own processor, which a
        // busy machine does not stretch.
        func processorSeconds() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
        }
        let started = processorSeconds()
        let segments = Myers.diff(a, b)
        #expect(isValid(segments, a, b))
        #expect(segments.contains { $0.isEqual })
        #expect(processorSeconds() - started < 60)
    }

    @Test func linesWithoutAPartnerAreTakenOutFirst() {
        // 200,000 lines on each side with nothing in common but three lines: no search to speak of.
        var a = (0..<200_000).map { "left \($0)" }
        var b = (0..<200_000).map { "right \($0)" }
        for (position, text) in [(10, "one"), (100_000, "two"), (199_990, "three")] {
            a[position] = text
            b[position + 5] = text
        }
        let segments = Myers.diff(a, b)
        #expect(isValid(segments, a, b))
        #expect(segments.filter(\.isEqual).map(\.a) == [10..<11, 100_000..<100_001, 199_990..<199_991])
    }

    @Test func aLargeFileWithFewChangesIsExact() {
        var a = (0..<120_000).map { "line \($0 % 5_000) of block \($0 / 5_000)" }
        var b = a
        b.remove(at: 70_000)
        b.insert("something new", at: 20_000)
        b[110_000] = "changed"
        a.append("tail")
        let segments = Myers.diff(a, b)
        #expect(isValid(segments, a, b))
        #expect(Myers.editDistance(segments) == 5)
    }

    @Test func cancelledDiffEndsEarlyButIsStillACover() {
        let flag = CancellationFlag()
        flag.cancel()
        let (a, b) = ([1, 2, 3, 4], [1, 3, 4, 5])
        let segments = Myers.diff(a, b, cancellation: flag)
        #expect(isValid(segments, a, b))
    }
}

@Suite struct TextComparing {
    func lines(_ text: String) -> [TextLine] { TextDocument.split(text) }

    func kinds(_ left: String, _ right: String, _ options: DiffOptions = DiffOptions()) -> String {
        TextDiff.compute(left: lines(left), right: lines(right), options: options).rows
            .map { row in
                switch row.kind {
                case .equal: return "="
                case .changed: return "~"
                case .added: return "+"
                case .removed: return "-"
                }
            }
            .joined()
    }

    @Test func encodingsAreDetectedAndWrittenBackUnchanged() {
        let samples: [(Data, TextEncoding, [String])] = [
            (Data("grüße\nwelt\n".utf8), .utf8(bom: false), ["grüße", "welt"]),
            (Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb".utf8), .utf8(bom: true), ["a", "b"]),
            (Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00, 0x0A, 0x00, 0xE4, 0x00]), .utf16LittleEndian, ["hi", "ä"]),
            (Data([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69, 0x00, 0x0D, 0x00, 0x6A]), .utf16BigEndian, ["hi", "j"]),
            (Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF]), .latin1, ["café", "ÿ"]),
            (Data(), .utf8(bom: false), [])
        ]
        for (data, encoding, texts) in samples {
            let document = TextDocument(data: data)
            #expect(document.encoding == encoding)
            #expect(document.lines.map(\.text) == texts)
            #expect(document.data() == data, "\(encoding.name)")
        }
        #expect(TextEncoding.utf16LittleEndian.name == "UTF-16 LE" && TextEncoding.latin1.name == "Latin-1")
    }

    @Test func linesKeepTheirOwnLineBreaks() {
        let document = TextDocument(data: Data("one\ntwo\r\nthree\rfour\n\nlast".utf8))
        #expect(document.lines.map(\.text) == ["one", "two", "three", "four", "", "last"])
        #expect(document.lines.map(\.ending) == [.lf, .crlf, .cr, .lf, .lf, .none])
        #expect(document.lines.map(\.number) == [1, 2, 3, 4, 5, 6] && document.usualEnding == .lf)
        #expect(
            TextDocument.split("\n").map(\.text) == [""] && TextDocument.split("").isEmpty
                && TextDocument.split("a\r").map(\.ending) == [.cr]
        )

        // A line put after a last line without a break gets the file's usual break.
        var windows = TextDocument(data: Data("a\r\nb\r\nc".utf8))
        windows.lines.append(TextLine("d", ending: .none))
        #expect(String(decoding: windows.data(), as: UTF8.self) == "a\r\nb\r\nc\r\nd")
    }

    @Test func binaryFilesAreRecognised() {
        #expect(TextDocument.looksBinary(Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01])))
        #expect(!TextDocument.looksBinary(Data("plain text".utf8)) && !TextDocument.looksBinary(Data()))
        #expect(!TextDocument.looksBinary(Data([0xFF, 0xFE, 0x68, 0x00])))
    }

    @Test func rowsShowChangedAddedAndRemovedLines() {
        #expect(kinds("a\nb\nc\n", "a\nb\nc\n") == "===")
        #expect(kinds("a\nb\nc\n", "a\nx\nc\n") == "=~=")
        #expect(kinds("a\nc\n", "a\nb\nc\n") == "=+=")
        #expect(kinds("a\nb\nc\n", "a\nc\n") == "=-=")
        #expect(kinds("a\nb\nc\nd\n", "a\nx\nd\n") == "=~-=")
        #expect(kinds("a\nb\nd\n", "a\nx\ny\nz\nd\n") == "=~++=")
        #expect(kinds("", "a\nb\n") == "++" && kinds("a\n", "") == "-" && kinds("", "") == "")

        let diff = TextDiff.compute(left: lines("a\nb\nc\nd\ne\nf\n"), right: lines("a\nX\nY\nd\ne\nf\ng\n"))
        // A run of differing rows is one difference.
        #expect(diff.blocks == [1..<3, 6..<7] && !diff.isIdentical)
        #expect(
            diff.rows[1] == DiffRow(left: 1, right: 1, kind: .changed)
                && diff.rows[6] == DiffRow(left: nil, right: 6, kind: .added)
        )
    }

    @Test func optionsDecideWhichLinesAreEqual() {
        let exact = DiffOptions(ignoreCase: false, ignoreRepeatedSpaces: false, ignoreLineEndings: false)
        #expect(kinds("Hello\n", "hello\n") == "=" && kinds("Hello\n", "hello\n", exact) == "~")
        #expect(kinds("  a   b\t c  \n", "a b c\n") == "=" && kinds("  a   b\t c  \n", "a b c\n", exact) == "~")
        #expect(kinds("ab\n", "a b\n") == "~")
        #expect(kinds("a\r\nb\r\n", "a\nb\n") == "==" && kinds("a\r\nb\n", "a\nb\n", exact) == "~=")
        #expect(kinds("a\nb", "a\nb\n") == "==" && kinds("a\nb", "a\nb\n", exact) == "=~")
        #expect(kinds("A  b\n", "a b\n", DiffOptions(ignoreCase: true, ignoreRepeatedSpaces: false)) == "~")
        #expect(kinds("ÄÖ\n", "äö\n") == "=")
        #expect(DiffOptions().key(TextLine("\t Mixed   CASE ")) == "mixed case")
        #expect(exact.key(TextLine(" x ", ending: .crlf)) == " x \r\n")
    }

    @Test func theRowsAlwaysRebuildTheRightFile() {
        var random = Seeded(state: 11)
        let words = ["alpha", "Alpha", "beta", " beta", "gamma  delta", "gamma delta", "", "end", "END", "x"]
        for round in 0..<300 {
            let left = (0..<Int.random(in: 0...30, using: &random))
                .map { _ in
                    TextLine(words.randomElement(using: &random)!)
                }
            let right = (0..<Int.random(in: 0...30, using: &random))
                .map { _ in
                    TextLine(words.randomElement(using: &random)!)
                }
            let options = DiffOptions(ignoreCase: round % 2 == 0, ignoreRepeatedSpaces: round % 3 == 0)
            let diff = TextDiff.compute(left: left, right: right, options: options)
            #expect(diff.rebuiltRight(left: left, right: right) == right)
            #expect(
                diff.rows.compactMap(\.left) == Array(left.indices)
                    && diff.rows.compactMap(\.right) == Array(right.indices)
            )
            for row in diff.rows where row.kind == .equal {
                #expect(options.key(left[row.left!]) == options.key(right[row.right!]))
            }
            #expect(diff.blocks.reduce(0) { $0 + $1.count } == diff.rows.filter { $0.kind != .equal }.count)
        }
    }

    @Test func longTextsAreKeyedOnAllCores() {
        let left = (0..<60_000).map { TextLine("Line   NUMBER \($0)") }
        var right = left.map { TextLine($0.text.lowercased().replacingOccurrences(of: "   ", with: " ")) }
        right[30_000].text = "different"
        right.remove(at: 5)
        let diff = TextDiff.compute(left: left, right: right)
        #expect(diff.blocks == [5..<6, 30_000..<30_001])
        #expect(diff.rebuiltRight(left: left, right: right) == right)
    }

    @Test func resyncAnchorsForceLinesTogether() {
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

    @Test func differencesInsideALine() {
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

@Suite struct BinaryComparing {
    @Test func bytesAreComparedAtTheSameOffsets() {
        let left = Data((0..<40).map { UInt8($0) })
        var right = left
        right[3] = 0xFF
        right[17] = 0xEE
        right[18] = 0xEE
        right.append(contentsOf: [1, 2, 3])
        let diff = BinaryDiff.compute(left: left, right: right, bytesPerLine: 8)
        #expect(diff.rowCount == 6 && diff.differingBytes == 6 && !diff.isIdentical)
        #expect(diff.blocks == [0..<1, 2..<3, 5..<6])
        #expect(
            diff.differingOffsets(left: left, right: right, row: 2) == [1, 2]
                && diff.differingOffsets(left: left, right: right, row: 5) == [0, 1, 2]
        )
        #expect(diff.differingOffsets(left: left, right: right, row: 1).isEmpty)
        #expect(diff.offsetText(row: 2) == "00000010")
        #expect(diff.text(of: Data("Hello, W".utf8) + Data([0, 0xFF]), row: 0) == "48 65 6C 6C 6F 2C 20 57  Hello, W")
        #expect(diff.text(of: Data("Hello, W".utf8) + Data([0, 0xFF]), row: 1) == "00 FF                    ..")
        #expect(diff.text(of: left, row: 5).isEmpty)
        #expect(diff.textRanges(ofByte: 2) == [6..<8, 27..<28])
    }

    @Test func edgeCases() {
        #expect(
            BinaryDiff.compute(left: Data(), right: Data()).isIdentical
                && BinaryDiff.compute(left: Data(), right: Data()).rowCount == 0
        )
        let one = BinaryDiff.compute(left: Data([1, 2, 3]), right: Data(), bytesPerLine: 16)
        #expect(one.blocks == [0..<1] && one.differingBytes == 3 && one.rowCount == 1)
        let same = BinaryDiff.compute(left: Data([9, 9]), right: Data([9, 9]), bytesPerLine: 1)
        #expect(same.isIdentical && same.blocks.isEmpty && same.rowCount == 2)
        // A slice of a larger buffer is addressed from its own start.
        let slice = Data([0, 0, 7, 8, 9]).dropFirst(2)
        let sliced = BinaryDiff.compute(left: slice, right: Data([7, 0, 9]), bytesPerLine: 2)
        #expect(
            sliced.differingOffsets(left: slice, right: Data([7, 0, 9]), row: 0) == [1]
                && sliced.text(of: slice, row: 1).hasPrefix("09")
        )
    }

    @Test func largeFilesAreComparedInPiecesOnAllCores() {
        var random = Seeded(state: 5)
        var left = Data(count: 3_000_000)
        left.withUnsafeMutableBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 8) {
                bytes.storeBytes(of: random.next(), toByteOffset: index, as: UInt64.self)
            }
        }
        var right = left
        let changed = [0, 65_535, 65_536, 65_552, 1_500_000, 2_999_999]
        for offset in changed { right[offset] ^= 0x55 }
        let diff = BinaryDiff.compute(left: left, right: right, bytesPerLine: 16)
        #expect(diff.differingBytes == changed.count)
        // 65,535 and 65,536 are neighbouring lines across a piece border, and 65,552 is the next: one difference.
        #expect(diff.blocks == [0..<1, 4_095..<4_098, 93_750..<93_751, 187_499..<187_500])
        #expect(BinaryDiff.compute(left: left, right: left).isIdentical)
    }
}

@Suite struct CompareLoading {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()

    init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    @Test func textFilesAreLoadedAndCompared() {
        memory.addFile("/a.txt", "one\ntwo\nthree\n")
        memory.addFile("/b.txt", "one\n2\nthree\nfour\n")
        let result = CompareLoader.load(
            left: memory.url("/a.txt"),
            right: memory.url("/b.txt"),
            fileSystems: fileSystems
        )
        guard case .text(let left, let right, let diff, let width) = result.content else {
            Issue.record("not a text comparison")
            return
        }
        #expect(!result.isIdentical && result.message == nil && left.lines.count == 3 && right.lines.count == 4)
        #expect(diff.blocks == [1..<2, 3..<4] && width == 5)
    }

    @Test func identicalAndBinaryAndMissingFiles() {
        memory.addFile("/a.txt", "same\n")
        memory.addFile("/b.txt", "same\n")
        memory.addFile("/c.txt", "SAME\n")
        memory.addFile("/x.bin", "ab\u{0}cd")
        memory.addDirectory("/folder")
        func load(_ left: String, _ right: String, binary: Bool = false) -> ComparedFiles {
            CompareLoader.load(
                left: memory.url(left),
                right: memory.url(right),
                forceBinary: binary,
                bytesPerLine: 8,
                fileSystems: fileSystems
            )
        }
        #expect(load("/a.txt", "/b.txt").isIdentical)
        // Equal for the options, but not the same content.
        let folded = load("/a.txt", "/c.txt")
        if case .text(_, _, let diff, _) = folded.content {
            #expect(diff.isIdentical)
        } else {
            Issue.record("not text")
        }
        #expect(!folded.isIdentical)

        if case .binary(_, _, let diff) = load("/x.bin", "/a.txt").content {
            #expect(diff.differingBytes == 5)
        } else {
            Issue.record("not binary")
        }
        if case .binary(_, _, let diff) = load("/a.txt", "/c.txt", binary: true).content {
            #expect(diff.differingBytes == 4 && diff.bytesPerLine == 8)
        } else {
            Issue.record("not binary")
        }
        #expect(load("/a.txt", "/missing.txt").message == "mem:/missing.txt is not a file.")
        #expect(load("/folder", "/a.txt").message == "mem:/folder is not a file.")
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            CompareLoader.load(
                left: memory.url("/a.txt"),
                right: memory.url("/c.txt"),
                fileSystems: fileSystems,
                cancellation: cancelled
            )
            .wasCancelled
        )
    }

    @Test func largeLocalFilesAreCheckedInStretchesOnAllCores() throws {
        let box = try Sandbox()
        var random = Seeded(state: 1)
        var data = Data(count: 1_000_003)
        data.withUnsafeMutableBytes { bytes in
            for index in 0..<bytes.count { bytes[index] = UInt8(truncatingIfNeeded: random.next()) }
        }
        var lastByte = data
        lastByte[data.count - 1] ^= 1
        var middle = data
        middle[500_000] ^= 1
        for (name, content) in [("a", data), ("same", data), ("last", lastByte), ("middle", middle)] {
            try content.write(to: box.url(name))
        }
        func identical(_ name: String, stretch: Int = 64 * 1_024, _ flag: CancellationFlag = CancellationFlag()) throws
            -> Bool?
        {
            try CompareLoader.identical(
                box.url("a"),
                box.url(name),
                size: Int64(data.count),
                fileSystems: fileSystems,
                cancellation: flag,
                stretch: stretch
            )
        }
        #expect(try identical("same") == true && identical("last") == false && identical("middle") == false)
        #expect(try identical("same", stretch: 1_000_003) == true && identical("last", stretch: 7_777) == false)
        let flag = CancellationFlag()
        flag.cancel()
        #expect(try identical("same", flag) == nil)
        #expect(throws: (any Error).self) { try identical("missing") }
    }

    @Test func filesElsewhereAreReadOnceSideBySide() throws {
        memory.isLocal = false
        let text = String(repeating: "0123456789abcdef", count: 200_000)
        memory.addFile("/a", text)
        memory.addFile("/b", text)
        memory.addFile("/c", text.dropLast() + "!")
        func identical(_ name: String) throws -> Bool? {
            try CompareLoader.identical(
                memory.url("/a"),
                memory.url(name),
                size: Int64(text.utf8.count),
                fileSystems: fileSystems,
                stretch: 4_096
            )
        }
        #expect(try identical("/b") == true && identical("/c") == false)
        // The same through the stretches, when the file system says it is local.
        memory.isLocal = true
        #expect(try identical("/b") == true && identical("/c") == false)
    }

    @Test func savingReplacesTheFileAndLeavesNothingBehind() throws {
        memory.addFile("/dir/file.txt", "old content", permissions: 0o600)
        try CompareLoader.replace(
            memory.url("/dir/file.txt"),
            with: Data("new content".utf8),
            fileSystems: fileSystems
        )
        #expect(memory.contents("/dir/file.txt") == "new content" && memory.allPaths == ["/dir", "/dir/file.txt"])
        #expect(memory.item(at: memory.url("/dir/file.txt"))?.permissions == 0o600)
        // A file that has gone meanwhile is written anew.
        try CompareLoader.replace(memory.url("/dir/fresh.txt"), with: Data("x".utf8), fileSystems: fileSystems)
        #expect(memory.contents("/dir/fresh.txt") == "x")
        #expect(throws: (any Error).self) {
            try CompareLoader.replace(memory.url("/nowhere/file.txt"), with: Data(), fileSystems: fileSystems)
        }

        let box = try Sandbox()
        try box.file("on-disk.txt", "before")
        try CompareLoader.replace(box.url("on-disk.txt"), with: Data("after".utf8), fileSystems: fileSystems)
        #expect(box.read("on-disk.txt") == "after" && namesOnDisk(box.root) == ["on-disk.txt"])
    }
}
