import AFMKernel
import AppKit
import Darwin
import Foundation
import ImageIO
import LocalFileSystemPlugin
import PDFKit
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import ViewerPlugin

/// Review round 2, second pass, the viewer: wide characters, the sequential scan of a giant line,
/// the limit on index builds, EUC-JP and GB 18030, printing, links, the pixel limit and a FIFO
/// that takes the place of a file.
@Suite struct Review2PluginsBP2Viewer {
    private func document(
        _ data: Data, encoding: ViewerEncoding = .utf8, columns: Int, wrap: Bool = true, segment: Int = 4 << 20,
        chunk: Int = 1 << 20,
        parallel: Bool = false, raw: Bool = true
    ) -> TextDocument {
        let document = TextDocument(
            source: DataByteSource(data), encoding: encoding,
            layout: .text(TextLayoutOptions(columns: columns, wordWrap: wrap)))
        document.buildIndex(parallel: parallel, segmentSize: segment, chunkSize: chunk, rawScan: raw)
        return document
    }

    private func rows(_ document: TextDocument) throws -> [String] {
        try document.rows(from: 0, count: max(1, document.rowCount)).map(\.text)
    }

    // MARK: East Asian width (V035)

    @Test func theEastAsianWidthTableKnowsWideAndNarrowCharacters() {
        for scalar: UInt32 in [
            0x1100, 0x3042, 0x4E00, 0xAC00, 0xFF21, 0xFFE0, 0x1F600, 0x20000, 0x2FFFD, 0x3000, 0x231A
        ] {
            #expect(EastAsianWidth.isWide(scalar), "U+\(String(scalar, radix: 16))")
        }
        for scalar: UInt32 in [
            0x41, 0xE9, 0x20A0, 0x0E01, 0xFF61 + 0x20, 0x1D400, 0xE000, 0x2FFFE, 0xFFE8, 0x10FFFF, 0x30, 0x300, 0xD7A4
        ] {
            if scalar == 0xFF61 + 0x20 { continue }  // U+FF81, a half-width katakana, is narrow
            #expect(!EastAsianWidth.isWide(scalar), "U+\(String(scalar, radix: 16))")
        }
        #expect(!EastAsianWidth.isWide(0xFF81))
    }

    @Test func wideCharactersTakeTwoColumnsInTheRows() throws {
        let data = Data("日本語日本語日本語\n".utf8)
        // Six columns hold three wide characters.
        #expect(try rows(document(data, columns: 6)) == ["日本語", "日本語", "日本語"])
        // Odd widths: a wide character that does not fit goes to the next row.
        let five = try rows(document(data, columns: 5))
        #expect(five == ["日本", "語日", "本語", "日本", "語"])
        // Mixed with narrow ones.
        #expect(try rows(document(Data("ab日本語\n".utf8), columns: 5, wrap: false)) == ["ab日", "本語"])
        // One column holds one wide character (a row is never empty).
        #expect(try rows(document(Data("日本\n".utf8), columns: 1)) == ["日", "本"])
    }

    @Test func characterOutsideTheBasicPlaneAreMeasuredAsOneCharacter() throws {
        // Emoji and U+20000 are wide; a mathematical letter is not.
        #expect(try rows(document(Data("😀😀😀\n".utf8), columns: 4)) == ["😀😀", "😀"])
        #expect(
            try rows(document(Data("\u{20000}\u{20000}\u{20000}\n".utf8), columns: 4)) == [
                "\u{20000}\u{20000}", "\u{20000}"
            ])
        #expect(try rows(document(Data("𝐀𝐀𝐀𝐀\n".utf8), columns: 2)) == ["𝐀𝐀", "𝐀𝐀"])
        // In a row of one column a wide character is past the width at once; its second half stays with it.
        #expect(try rows(document(Data("😀😀\n".utf8), columns: 1)) == ["😀", "😀"])
        #expect(try rows(document(Data("日\u{301}日\n".utf8), columns: 1)) == ["日\u{301}", "日"])
        // A combining mark after a wide character adds no column.
        #expect(
            try rows(document(Data("日\u{301}日\u{301}日\u{301}\n".utf8), columns: 4)) == ["日\u{301}日\u{301}", "日\u{301}"])
    }

    @Test func wideCharactersInUTF16AreCutLikeThoseInUTF8() throws {
        // Four units, eight columns: the raw scan of a short line must not take it for one row of six.
        let text = "日本語日\n"
        let data = try #require(text.data(using: .utf16LittleEndian))
        #expect(try rows(document(data, encoding: .utf16LE, columns: 6)) == ["日本語", "日"])
        let big = try #require(text.data(using: .utf16BigEndian))
        #expect(try rows(document(big, encoding: .utf16BE, columns: 6)) == ["日本語", "日"])
    }

    @Test func theFastScanAndTheDecodingScanAgreeOnWideText() throws {
        let pieces = ["a", "日", "😀", "\u{301}", "漢字", " ", "x", "é", "ｱ", "\t", "한", "𝐀"]
        var state: UInt64 = 0x1234_5678
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        for round in 0..<40 {
            var text = ""
            for _ in 0..<(1 + next() % 40) {
                for _ in 0..<(next() % 30) { text += pieces[next() % pieces.count] }
                text += next() % 7 == 0 ? "\r\n" : "\n"
            }
            let columns = 1 + next() % 12
            for encoding in [ViewerEncoding.utf8, .utf16LE, .utf16BE] {
                let data = try #require(
                    text.data(
                        using: encoding == .utf8 ? .utf8 : encoding == .utf16LE ? .utf16LittleEndian : .utf16BigEndian))
                let fast = document(
                    data, encoding: encoding, columns: columns, wrap: false, segment: 64, chunk: 40, raw: true)
                let plain = document(data, encoding: encoding, columns: columns, wrap: false, raw: false)
                #expect(
                    fast.rowCount == plain.rowCount && fast.lineCount == plain.lineCount,
                    "round \(round) \(encoding.name) columns \(columns)")
                #expect(try rows(fast) == rows(plain), "round \(round) \(encoding.name) columns \(columns)")
            }
        }
    }

    // MARK: A sequential scan reads a giant line once (V069)

    private final class CountingSource: ByteSource {
        let base: any ByteSource
        private let lock = NSLock()
        private var total: Int64 = 0
        init(_ base: any ByteSource) { self.base = base }
        var length: Int64 { base.length }
        var bytesRead: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return total
        }

        func read(at offset: Int64, count: Int) throws -> Data {
            let data = try base.read(at: offset, count: count)
            lock.lock()
            total += Int64(data.count)
            lock.unlock()
            return data
        }
    }

    @Test func aSequentialScanDoesNotReadAGiantLineTwice() throws {
        var data = Data(repeating: UInt8(ascii: "a"), count: 400_000)
        data.append(Data("\nsecond line\nthird\n".utf8))
        let source = CountingSource(DataByteSource(data))
        let counted = TextDocument(
            source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        counted.buildIndex(parallel: false, segmentSize: 64 << 10, chunkSize: 32 << 10)
        #expect(counted.isIndexComplete && counted.readError == nil)
        // The first segment reads the line to its end; the segments inside the line are not read at all.
        #expect(source.bytesRead < Int64(Double(data.count) * 1.25), "read \(source.bytesRead) of \(data.count)")
        let reference = document(data, columns: 80, segment: 64 << 10, chunk: 32 << 10, parallel: true)
        #expect(counted.rowCount == reference.rowCount && counted.lineCount == reference.lineCount)
        #expect(try rows(counted) == rows(reference))
        #expect(counted.lineCount == 3 && counted.rowCount == 400_000 / 80 + 2)
    }

    @Test func sequentialAndParallelScansGiveTheSameRowsWhateverTheLinesAndSegments() throws {
        var state: UInt64 = 99
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        for round in 0..<30 {
            var text = ""
            for _ in 0..<(1 + next() % 12) {
                // Lines of every length, some far longer than a segment, some empty.
                let length = [0, 1, 5, 40, 300, 2_000, 9_000][next() % 7]
                for _ in 0..<length { text += ["a", "b", "日", " ", "é"][next() % 5] }
                text += ["\n", "\r\n", "\r"][next() % 3]
            }
            let data = Data(text.utf8)
            let columns = [3, 10, 80][next() % 3]
            let segment = [7, 64, 1_000, 4_096][next() % 4]
            let chunk = [16, 100, 4_096][next() % 3]
            let sequential = document(data, columns: columns, segment: segment, chunk: chunk, parallel: false)
            let parallel = document(data, columns: columns, segment: segment, chunk: chunk, parallel: true)
            let whole = document(data, columns: columns)
            #expect(
                sequential.rowCount == whole.rowCount && sequential.lineCount == whole.lineCount,
                "round \(round) segment \(segment)")
            #expect(
                parallel.rowCount == whole.rowCount && parallel.lineCount == whole.lineCount,
                "round \(round) segment \(segment)")
            #expect(try rows(sequential) == rows(whole), "round \(round) segment \(segment) chunk \(chunk)")
        }
    }

    // MARK: At most so many index builds in flight (V024)

    private final class Latch {
        private let condition = NSCondition()
        private var open = false
        private var started: [Int] = []

        func wait() {
            condition.lock()
            while !open { condition.wait() }
            condition.unlock()
        }

        func release() {
            condition.lock()
            open = true
            condition.broadcast()
            condition.unlock()
        }

        func started(_ number: Int) {
            condition.lock()
            started.append(number)
            condition.unlock()
        }

        var startedJobs: [Int] {
            condition.lock()
            defer { condition.unlock() }
            return started.sorted()
        }
    }

    private func wait(_ seconds: Double = 30, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        return condition()
    }

    @Test func theGateRunsFewJobsAtOnceAndDropsWhatWasCancelledBeforeItsTurn() {
        let gate = ViewerWorkGate(live: 2, stuck: 4)
        let latch = Latch()
        let flags = (1...5).map { _ in CancellationFlag() }
        for (index, flag) in flags.enumerated() {
            gate.submit(cancellation: flag) {
                latch.started(index + 1)
                latch.wait()
            }
        }
        #expect(wait { latch.startedJobs.count == 2 })
        #expect(latch.startedJobs == [1, 2] && gate.threadsInUse == 2 && gate.waitingCount == 3)
        // Job 3 is given up before its turn: it never runs.
        flags[2].cancel()
        #expect(gate.waitingCount == 2)
        // Job 1 is cancelled while it runs (stuck in a read): it holds its thread but no longer counts, so job 4 starts.
        flags[0].cancel()
        #expect(wait { latch.startedJobs.contains(4) })
        #expect(gate.threadsInUse == 3)
        latch.release()
        #expect(wait { gate.threadsInUse == 0 })
        #expect(latch.startedJobs == [1, 2, 4, 5])
    }

    @Test func whenTooManyCancelledJobsAreStuckANewOneIsRefused() {
        let gate = ViewerWorkGate(live: 1, stuck: 2)
        let latch = Latch()
        var flags: [CancellationFlag] = []
        for number in 1...2 {
            let flag = CancellationFlag()
            flags.append(flag)
            gate.submit(cancellation: flag) {
                latch.started(number)
                latch.wait()
            }
            #expect(wait { latch.startedJobs.contains(number) })
            // Cancelled, and still inside its read.
            flag.cancel()
        }
        let refused = Locked(false)
        let ran = Locked(false)
        gate.submit(
            cancellation: CancellationFlag(), refused: { refused.withValue { $0 = true } },
            { ran.withValue { $0 = true } })
        #expect(refused.withValue { $0 } && !ran.withValue { $0 })
        #expect(gate.threadsInUse == 2)
        latch.release()
        #expect(wait { gate.threadsInUse == 0 })
        // With the threads back, a job runs again.
        let again = Latch()
        gate.submit(cancellation: CancellationFlag()) { again.started(1) }
        #expect(wait { again.startedJobs == [1] })
    }

    @Test func theSharedGateIsBoundedAndNeverBlocksItsCaller() {
        let gate = ViewerWorkGate.indexBuilds
        #expect(gate.live >= 2 && gate.live <= 4 && gate.stuck >= gate.live)
    }

    // MARK: EUC-JP and GB 18030 (revisited)

    /// The characters one by one: their bytes, so the start of every character is known without the decoder.
    private func encode(_ characters: [String], _ encoding: ViewerEncoding) throws -> (data: Data, starts: [Int]) {
        var data = Data()
        var starts: [Int] = []
        for character in characters {
            starts.append(data.count)
            data.append(contentsOf: try #require(encoding.encode(character), "\(character) in \(encoding.name)"))
        }
        return (data, starts)
    }

    @Test func eucJPAndGB18030AreOffered() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb = try #require(ViewerEncoding.codePage(54_936))
        #expect(euc.kind == .doubleByte && euc.shape == .eucJP && gb.kind == .doubleByte && gb.shape == .gb18030)
        #expect(euc.isAvailable && gb.isAvailable)
        let offered = ViewerEncoding.codePages.map(\.codePage)
        #expect(offered.contains(51_932) && offered.contains(54_936))
        #expect(!euc.byteOriented.isUnicode && euc.byteOriented == .ansi)
        // Another code page of many bytes is still not offered.
        #expect(ViewerEncoding.codePage(50_220) == nil)
    }

    @Test func eucJPTextIsDecodedWithItsOffsets() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let characters = ["日", "本", "語", "a", "ｱ", "ｲ", "テ", "キ", "ス", "ト", "、", " ", "b", "\n", "漢", "字"]
        let (data, starts) = try encode(characters, euc)
        #expect(data.count == starts.last! + 2)
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

    @Test func gb18030TextIsDecodedWithItsOffsets() throws {
        let gb = try #require(ViewerEncoding.codePage(54_936))
        // Two-byte characters, ASCII, four-byte ones in and beyond the Basic Multilingual Plane.
        let characters = ["中", "文", "a", "1", "\u{80}", "\u{FFFF}", "\u{20000}", "😀", "€", "龙", "9", "\n", "b"]
        let (data, starts) = try encode(characters, gb)
        var decoded = DecodedText()
        let used = gb.decode(data, final: true, into: &decoded)
        #expect(used == data.count)
        #expect(decoded.string == characters.joined())
        // The two halves of a character beyond the plane share their offset.
        var expected: [Int] = []
        for (character, start) in zip(characters, starts) {
            expected += Array(repeating: start, count: character.utf16.count)
        }
        #expect(decoded.offsets.map(Int.init) == expected)
        // Four-byte structure that does not hold up: stray bytes, and what follows keeps its own meaning (0x8141 is a pair).
        var stray = DecodedText()
        gb.decode(Data([0x81, 0x30, 0x41, 0x81, 0x30, 0x81, 0x41, 0x81, 0x7F, 0xFF]), final: true, into: &stray)
        #expect(stray.units == [0xFFFD, 0x30, 0x41, 0xFFFD, 0x30, 0x4E04, 0xFFFD, 0x7F, 0xFFFD])
    }

    @Test func textDecodedInPiecesEqualsTextDecodedWhole() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb = try #require(ViewerEncoding.codePage(54_936))
        let eucData =
            try encode(["日", "本", "a", "ｱ", "語", "\n", "テ", "ス", "ト", "漢"], euc).data
            + Data([0x8F, 0xB0, 0xA1, 0x41, 0x8E])
        let gbData =
            try encode(["中", "\u{80}", "a", "😀", "文", "\n", "龙", "9", "\u{FFFF}", "€"], gb).data
            + Data([0x81, 0x30, 0x81])
        for (encoding, data) in [(euc, eucData), (gb, gbData)] {
            var whole = DecodedText()
            encoding.decode(data, final: true, into: &whole)
            for cut in 1...9 {
                var units: [UInt16] = []
                var offsets: [Int] = []
                var at = 0
                var piece = DecodedText()
                while at < data.count {
                    var end = min(data.count, at + cut)
                    var took = 0
                    while true {
                        let final = end == data.count
                        took = encoding.decode(Array(data[at..<end]), final: final, into: &piece)
                        if took > 0 || final { break }
                        end = min(data.count, end + 1)
                    }
                    units += piece.units
                    offsets += piece.offsets.map { Int($0) + at }
                    at += took
                    if took == 0 { break }
                }
                #expect(units == whole.units && offsets == whole.offsets.map(Int.init), "\(encoding.name) cut \(cut)")
            }
        }
    }

    @Test func characterBoundariesAreExactInEUCJPAndGB18030() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb = try #require(ViewerEncoding.codePage(54_936))
        // Long runs without a byte that stands by itself: the boundary cannot be guessed from the neighbours.
        let kanji = (0..<400).map { ["日", "本", "語", "漢", "字", "龍"][$0 % 6] }
        let rareGB = (0..<400).map { ["\u{20000}", "龙", "\u{80}", "文", "😀", "中"][$0 % 6] }
        let mixedGB = (0..<400).map { ["\u{20000}", "龙", "1", "文", "9", "中", "a", "\u{FFFF}"][$0 % 8] }
        let mixedEUC = (0..<400).map { ["日", "ｱ", "a", "本", "ｲ", "語", "\n", "字"][$0 % 8] }
        for (encoding, characters) in [(euc, kanji), (gb, rareGB), (gb, mixedGB), (euc, mixedEUC)] {
            let (data, starts) = try encode(characters, encoding)
            for spacing in [16, 17, 50, 1 << 14] {
                let boundaries = CharacterBoundaries(
                    source: DataByteSource(data), content: 0..<Int64(data.count), encoding: encoding, spacing: spacing
                )
                var expected = 0
                for offset in stride(from: data.count - 1, through: 0, by: -3) {
                    while expected + 1 < starts.count, starts[expected + 1] <= offset { expected += 1 }
                    // Walk back to the character offset is in.
                    let want = starts.last(where: { $0 <= offset })!
                    #expect(
                        try boundaries.characterStart(atOrBefore: Int64(offset)) == Int64(want),
                        "\(encoding.name) spacing \(spacing) offset \(offset)")
                }
            }
        }
    }

    @Test func aSearchInEUCJPAndGB18030FindsWholeCharactersWhateverTheChunkSize() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb = try #require(ViewerEncoding.codePage(54_936))
        for (encoding, characters, needle) in [
            (
                euc, (0..<300).map { ["日", "本", "語", "漢", "字"][$0 % 5] } + ["龍", "亀"] + (0..<20).map { _ in "日" }, "龍亀"
            ),
            (
                gb,
                (0..<300).map { ["\u{20000}", "龙", "\u{80}", "文"][$0 % 4] } + ["龙", "亀"] + (0..<20).map { _ in "文" },
                "龙亀"
            )
        ] {
            let (data, starts) = try encode(characters, encoding)
            let at = starts[300]
            let want = Int64(at)..<Int64(starts[302])
            for chunk in [3, 7, 16, 61, 4_096] {
                let pattern = try SearchPattern(needle, options: SearchOptions(), encoding: encoding)
                let found = try ViewerSearch.find(
                    pattern, in: DataByteSource(data), content: 0..<Int64(data.count), from: 0, backwards: false,
                    encoding: encoding,
                    chunkSize: chunk)
                #expect(found == want, "\(encoding.name) chunk \(chunk)")
                var backwards = SearchOptions()
                backwards.backwards = true
                let last = try ViewerSearch.find(
                    try SearchPattern(needle, options: backwards, encoding: encoding), in: DataByteSource(data),
                    content: 0..<Int64(data.count), from: Int64(data.count), backwards: true, encoding: encoding,
                    chunkSize: chunk)
                #expect(last == want, "\(encoding.name) backwards chunk \(chunk)")
            }
        }
    }

    @Test func aTextDocumentInGB18030AndEUCJPShowsItsRows() throws {
        let euc = try #require(ViewerEncoding.codePage(51_932))
        let gb = try #require(ViewerEncoding.codePage(54_936))
        let eucText = "日本語のテキスト\nｱｲｳ abc\n漢字\n"
        let gbText = "中文 \u{20000} 文本\n€ 龙\n"
        for (encoding, text) in [(euc, eucText), (gb, gbText)] {
            let data = try #require(encoding.encode(text))
            let shown = try rows(document(Data(data), encoding: encoding, columns: 80, segment: 7, chunk: 5))
            #expect(shown == text.split(separator: "\n").map(String.init), "\(encoding.name)")
        }
    }

    // MARK: Printing (the whole text, to a page limit)

    @Test func printingCoversALongTextInFull() {
        // 40,000 lines of 50 bytes: 2 MB, which the old limit of 512 KB cut at a quarter.
        let line = String(repeating: "x", count: 49)
        let text = (1...40_000).map { _ in line }.joined(separator: "\n") + "\n"
        let doc = document(Data(text.utf8), columns: 200)
        let all = ViewerPane.printableText(of: doc, in: doc.content)
        #expect(all.lines.count == 40_000 && !all.truncated)
        let cut = ViewerPane.printableText(of: doc, in: doc.content, maxRows: 1_200)
        #expect(cut.lines.count == 1_200 && cut.truncated)
        let exact = ViewerPane.printableText(of: doc, in: doc.content, maxRows: 40_000)
        #expect(exact.lines.count == 40_000 && !exact.truncated)
        #expect(ViewerPane.printPageLimit >= 1_000)
        // A part of the text.
        let part = ViewerPane.printableText(of: doc, in: 0..<500)
        #expect(part.lines.count == 10 && part.text == String(repeating: line + "\n", count: 10))
    }

    @MainActor @Test func theTextForPrintingIsDrawnPageByPage() throws {
        let lines = (1...130).map { "line \($0)" }
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let page = NSSize(width: 400, height: 300)
        let perPage = TextPrintView.linesPerPage(font: font, pageHeight: page.height)
        let view = TextPrintView(lines: lines, font: font, pageSize: page)
        #expect(perPage >= 10 && view.pageCount == (130 + perPage - 1) / perPage)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range == NSRange(location: 1, length: view.pageCount))
        let second = view.rectForPage(2)
        #expect(
            second.origin.y == CGFloat(perPage) * TextPrintView.lineHeight(of: font) && second.height <= page.height)
        // The last page holds what is left, and every page can be drawn.
        for number in 1...view.pageCount {
            let rect = view.rectForPage(number)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: rep)
        }
        // An empty text is one empty page.
        #expect(TextPrintView(lines: [], font: font, pageSize: page).pageCount == 1)
    }

    // MARK: Links in RTF and PDF (V021)

    @MainActor @Test func onlyWebAndMailLinksAreOpenedFromRTFAndPDF() {
        let opened = Locked<[URL]>([])
        let gate = LinkGate(opener: { url in opened.withValue { $0.append(url) } })
        let textView = NSTextView()
        for link: Any in [
            URL(string: "https://example.com/a")!, "http://example.org", URL(string: "mailto:me@example.com")!,
            NSURL(string: "https://nsurl.example")!
        ] {
            #expect(gate.textView(textView, clickedOnLink: link, at: 0))
        }
        for link: Any in [
            URL(string: "file:///etc/passwd")!, "smb://server/share", URL(string: "afp://x")!, "javascript:alert(1)",
            URL(string: "x-apple.systempreferences:")!, 42
        ] {
            // Handled all the same: the text view does not open it by itself.
            #expect(gate.textView(textView, clickedOnLink: link, at: 0))
        }
        gate.pdfViewWillClick(onLink: PDFView(), with: URL(string: "https://pdf.example/x.pdf")!)
        gate.pdfViewWillClick(onLink: PDFView(), with: URL(string: "file:///Users/someone/secret")!)
        gate.pdfViewWillClick(onLink: PDFView(), with: URL(string: "ssh://host")!)
        #expect(
            opened.withValue { $0.map(\.absoluteString) } == [
                "https://example.com/a", "http://example.org", "mailto:me@example.com", "https://nsurl.example",
                "https://pdf.example/x.pdf"
            ])
    }

    @MainActor @Test func theRichViewsAreGivenTheGateAsTheirDelegate() {
        let (_, text) = RichViews.textView(NSAttributedString(string: "link"))
        #expect(text.delegate is LinkGate)
        #expect(RichViews.pdfView(PDFDocument()).delegate is LinkGate)
    }

    // MARK: The pixel limit (V034)

    private func png(_ width: Int, _ height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func anImageThatClaimsMorePixelsThanTheLimitIsNotDecoded() throws {
        let file = try png(64, 32)
        #expect(ImageDecoder.pixelLimit == 400_000_000)
        #expect(ImageDecoder.decode(file) != nil)
        #expect(ImageDecoder.decode(file, pixelLimit: 64 * 32) != nil)
        #expect(ImageDecoder.decode(file, pixelLimit: 64 * 32 - 1) == nil)
        // The same for a file on the disk.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("afm-bp2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("p.png")
        try file.write(to: url)
        #expect(ImageDecoder.decode(contentsOf: url) != nil)
        #expect(ImageDecoder.decode(contentsOf: url, pixelLimit: 100) == nil)
    }

    // MARK: A link whose target size the file system gave (L016)

    private final class LinkProvider: FileSystemProvider {
        let scheme = "link"
        let capabilities: FileSystemCapabilities = []
        let entry: FileItem
        init(_ entry: FileItem) { self.entry = entry }
        func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }
        func parent(of _: URL) -> URL? { nil }
        func createDirectory(at _: URL) {}
        func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("x") }
        func remove(_: URL) {}
        func move(_: URL, to _: URL, replacing _: Bool) {}
        func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) {}
        func item(at _: URL) -> FileItem? { entry }
        func read(_: URL) throws -> any FileReader {
            throw FileSystemError.notSupported("a link whose target size is known is not read to be measured")
        }
    }

    @Test func aLinkWhoseTargetSizeIsKnownIsNotReadToMeasureIt() throws {
        let url = URL(string: "link:///current.log")!
        let entry = FileItem(
            url: url, name: "current.log", isDirectory: false, isSymlink: true, size: 0, linkTargetSize: 123_456)
        let registry = FileSystemRegistry()
        registry.register(LinkProvider(entry))
        let source = try ProviderByteSource.open(url, fileSystems: registry)
        #expect(source is ProviderByteSource && source.length == 123_456)
    }

    // MARK: Closing at the end

    @Test func theTemporaryCopiesAreDeletedInTheBackgroundWhenTheProgramQuits() {
        let copies = TemporaryCopies()
        let memory = MemoryFileSystem()
        memory.addFile("/remote/clip.mov", String(repeating: "m", count: 5_000))
        let registry = FileSystemRegistry()
        registry.register(memory)
        let owner = ObjectIdentifier(copies)
        guard
            case .success(let local) = copies.localCopy(
                for: memory.url("/remote/clip.mov"), fileSystems: registry, owner: owner,
                cancellation: CancellationFlag())
        else {
            Issue.record("no copy")
            return
        }
        #expect(FileManager.default.fileExists(atPath: local.path))
        let done = DispatchSemaphore(value: 0)
        copies.removeAll(waiting: false, then: { done.signal() })
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(!FileManager.default.fileExists(atPath: local.path))
        // Nothing left: the answer comes at once, and once.
        let again = DispatchSemaphore(value: 0)
        copies.removeAll(waiting: false, then: { again.signal() })
        #expect(again.wait(timeout: .now() + 30) == .success)
    }

    // MARK: A FIFO that takes the place of a file

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("afm-bp2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aFileSwappedForAFIFOAfterItWasOpenedDoesNotHoldUpTheRead() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("f.txt")
        try Data(repeating: UInt8(ascii: "z"), count: 1_000).write(to: url)
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let source = try ProviderByteSource.open(url, fileSystems: registry)
        #expect(source.length == 1_000)
        #expect(try source.read(at: 0, count: 4) == Data("zzzz".utf8))
        // The reader that was kept belongs to the old file; a source closed meanwhile has none.
        source.close()
        ViewerCleanup.drain()
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        let done = DispatchSemaphore(value: 0)
        let outcome = Locked<Result<Data, any Error>?>(nil)
        let thread = Thread {
            outcome.withValue { $0 = Result { try source.read(at: 0, count: 10) } }
            done.signal()
        }
        thread.start()
        let finished = done.wait(timeout: .now() + 30) == .success
        if !finished {
            // Let the stuck open go, so the thread ends.
            let fd = open(url.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        #expect(finished, "the read of a FIFO did not return")
        if case .success(let data)? = outcome.withValue({ $0 }) { #expect(data.isEmpty, "a FIFO must not give bytes") }
    }

    @Test func aFIFOIsRefusedWhenOpeningAndWhenReadingDirectly() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pipe")
        #expect(mkfifo(url.path, 0o600) == 0)
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        #expect(throws: (any Error).self) { try ProviderByteSource.open(url, fileSystems: registry) }
        let direct = ProviderByteSource(url: url, provider: LocalFileSystem(), length: 100)
        let done = DispatchSemaphore(value: 0)
        let threw = Locked(false)
        Thread {
            do { _ = try direct.read(at: 0, count: 10) } catch { threw.withValue { $0 = true } }
            done.signal()
        }.start()
        let finished = done.wait(timeout: .now() + 30) == .success
        if !finished {
            let fd = open(url.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        #expect(finished && threw.withValue { $0 })
    }
}

/// A value that several threads look at.
private final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
