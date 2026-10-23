import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FilePropertiesPlugin
@testable import FileToolsPlugin
@testable import MultiRenamePlugin
@testable import ViewerPlugin

// Review round 2, integration: the four defects of the last fuzz campaign (N1–N4 of
// `status/harnesses.md`, reproducers under `Tests/Fuzz/repro/new/`).

@Suite
internal struct Review2IntegrationFuzz {
    // MARK: N1 — a yEnc part header with numbers nobody can mean

    private func decode(_ text: String) throws -> (outcome: Decoder.Outcome, memory: MemoryFileSystem) {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        let source = memory.addFile("/in/post.ync", text)
        memory.addDirectory("/out")
        let item = try #require(registry.item(at: source))
        return (
            try Decoder.decodeChecked(
                item,
                into: memory.url("/out"),
                autoRename: false,
                run: ToolRun(fileSystems: registry)
            ), memory
        )
    }

    @Test
    internal func aPartRangeThatCannotBeIsADamagedHeaderAndNoTrap() throws {
        // The reproducer, and its relatives: every pair far apart, upside down, or before the first byte.
        for range in [
            "begin=-9223372036854775808 end=0", "begin=-1 end=9223372036854775807", "begin=0 end=10", "begin=9 end=3",
            "begin=1 end=x", "begin=-9223372036854775808 end=9223372036854775807"
        ] {
            let (outcome, _) = try decode(
                "=ybegin part=1 line=128 size=3 name=a.bin\n=ypart \(range)\n" + "\u{8b}\u{8c}\u{8d}\n"
                    + "=yend size=3 part=1\n"
            )
            #expect(outcome.problems.contains { $0.contains("range of the part") }, "\(range): \(outcome.problems)")
        }
        // The largest part there can be is a number like any other.
        let (whole, _) = try decode(
            "=ybegin part=1 line=128 size=3 name=a.bin\n=ypart begin=1 end=9223372036854775807\nKLM\n=yend size=3 part=1\n"
        )
        #expect(whole.problems.contains { $0.contains("the part holds 9223372036854775807") }, "\(whole.problems)")
        // A part that is what it says is decoded without a word.
        let (good, memory) = try decode(
            "=ybegin part=1 line=128 size=3 name=a.bin\n=ypart begin=1 end=3\nKLM\n=yend size=3 part=1\n"
        )
        #expect(good.problems.isEmpty && memory.contents("/out/a.bin") == "!\"#", "\(good.problems)")
    }

    // MARK: N2 — the raw row scan at a segment's end

    private func rows(_ data: Data, columns: Int, segment: Int, chunk: Int, raw: Bool, parallel: Bool = false) throws
        -> (ranges: [Range<Int64>], lines: Int)
    {
        let document = TextDocument(
            source: DataByteSource(data),
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: columns, wordWrap: false, tabWidth: 8)),
            reusing: nil
        )
        document.buildIndex(
            parallel: parallel,
            scanning: TextRowIndex.ScanOptions(segmentSize: segment, chunkSize: chunk, rawScan: raw)
        ) {
            // Not watched here.
        }
        return (
            try document.rows(from: 0, count: max(1, document.rowCount), cancellation: nil).map(\.range),
            document.lineCount
        )
    }

    @Test
    internal func aRunOfEmptyLinesBehindALineThatReachesOverASegmentsEndMakesNoRowOfItsOwn() throws {
        // The reproducer (segments of one byte): the decoding scan was right, the raw scan made a seventh row.
        let small = Data([0, 0, 10, 10, 10, 10, 10])
        let reference = try rows(small, columns: 1, segment: 1 << 22, chunk: 1 << 20, raw: false)
        #expect(reference.ranges == [0..<1, 1..<3, 3..<4, 4..<5, 5..<6, 6..<7] && reference.lines == 5)
        for segment in [1, 2, 3, 5] {
            let raw = try rows(small, columns: 1, segment: segment, chunk: 1, raw: true)
            #expect(raw.ranges == reference.ranges && raw.lines == reference.lines, "segment \(segment): \(raw)")
        }
    }

    @Test
    internal func theSameAtTheSizesTheProgramUses() throws {
        // Lines of 8 bytes up to just before the end of the first segment of 4 MiB; then a line
        // that reaches over that end by 0 to 6 bytes; then five empty lines; then more text.
        for over in 0...6 {
            var data = Data()
            let boundary = 4 << 20
            let before = boundary - 3
            data.append(Data(repeating: UInt8(ascii: "a"), count: 7 + before % 8))
            data.append(10)
            while data.count + 8 <= before { data.append(contentsOf: Array("abcdefg\n".utf8)) }
            data.append(Data(repeating: UInt8(ascii: "x"), count: boundary - data.count + over))
            data.append(contentsOf: [10, 10, 10, 10, 10, 10])
            data.append(contentsOf: Array("tail of the text\nand its last line".utf8))
            let reference = try rows(data, columns: 80, segment: 1 << 30, chunk: 1 << 20, raw: false)
            for parallel in [false, true] {
                let raw = try rows(data, columns: 80, segment: 4 << 20, chunk: 1 << 20, raw: true, parallel: parallel)
                #expect(
                    raw.lines == reference.lines && raw.ranges.count == reference.ranges.count,
                    "over by \(over), parallel \(parallel)"
                )
                #expect(raw.ranges.suffix(12) == reference.ranges.suffix(12), "over by \(over), parallel \(parallel)")
            }
        }
    }

    // MARK: N3 — a comment file whose code-page bytes are valid UTF-8

    @Test
    internal func aRewriteOfACommentFileGivesEveryNameBack() {
        // The reproducer: read in the Windows code page (the first line is no UTF-8), one entry
        // whose name is the bytes of two byte-order marks.
        let reproducer = Data([0x20, 0xF8, 0x0A, 0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF])
        let first = DescriptIon(data: reproducer)
        #expect(first.entries.map(\.name) == ["ï»¿ï»¿"])
        #expect(DescriptIon(data: first.data()).entries == first.entries)
        // The same for any name whose code-page bytes happen to be UTF-8.
        var file = DescriptIon(data: Data([0xE9, 0x20, 0x78, 0x0D, 0x0A]))
        #expect(file.entries.map(\.name) == ["é"])
        file.setComment("", for: "é")
        file.setComment("a comment", for: "Ã©.txt")
        file.setComment("another", for: "ï»¿")
        let again = DescriptIon(data: file.data())
        #expect(again.entries == file.entries && again.entries.map(\.name) == ["Ã©.txt", "ï»¿"])
        // And once more, from what was written.
        #expect(DescriptIon(data: again.data()).entries == file.entries)
        // Plain names are written in the code page as before, without a mark.
        var plain = DescriptIon(data: Data([0xE9, 0x20, 0x78, 0x0D, 0x0A]))
        plain.setComment("y", for: "ü.txt")
        #expect(
            plain.data() == Data([0xE9, 0x20, 0x78, 0x0D, 0x0A, 0xFC, 0x2E, 0x74, 0x78, 0x74, 0x20, 0x79, 0x0D, 0x0A])
        )
    }

    // MARK: N4 — a long plain search in a long name

    @Test
    internal func aLongWildcardSearchInALongNameIsBoundedLikeARegularExpression() {
        var context = RenameContext()
        context.timeZone = TimeZone(identifier: "UTC") ?? .current
        var settings = RenameSettings()
        // Thousands of places the search can begin at, each of which nearly fits.
        settings.search = (0..<40).map { _ in String(repeating: "a*", count: 12) + "b" }.joined(separator: "|")
        settings.replacement = "x"
        let name = String(repeating: "aé", count: 1_500) + ".txt"
        let engine = RenameEngine(settings, context: context)
        let started = ThreadTime.used
        let result = engine.newName(for: RenameSubject(name: name), index: 0)
        let used = ThreadTime.used - started
        // Either it is worked out or it is given up as taking too long; it never takes seconds.
        #expect(used < 1.5, "\(used) s of work for one name")
        #expect(result == nil || result == name)
        // What the matcher finds is what it found before.
        let matcher = WildcardMatcher("a*É?", caseSensitive: false)
        #expect(
            matcher.matches(in: "xaBCéd-AéZ", firstOnly: false) == [
                NSRange(location: 1, length: 5), NSRange(location: 7, length: 3)
            ]
        )
        #expect(
            WildcardMatcher("*é", caseSensitive: true).matches(in: "aÉbéc", firstOnly: false) == [
                NSRange(location: 0, length: 4)
            ]
        )
    }
}
