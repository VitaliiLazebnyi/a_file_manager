import AFMKernel
import Foundation
import TestSupport
import Testing
@testable import ViewerPlugin

/// Fixes to the viewer found in review: search context at chunk borders and in double-byte
/// texts, the raw-byte row scan, partial results of a huge line, decoding without offsets,
/// HTML as text, cached remote reads and temporary copies.
@Suite struct ViewerFix {
    // MARK: Search

    private func find(_ pattern: String, _ options: SearchOptions = SearchOptions(), in data: Data, from start: Int64 = 0, encoding: ViewerEncoding = .utf8,
                      chunkSize: Int = 1 << 20) throws -> Range<Int64>? {
        let pattern = try SearchPattern(pattern, options: options, encoding: encoding)
        return try ViewerSearch.find(pattern, in: DataByteSource(data), content: 0..<Int64(data.count), from: start, backwards: options.backwards,
                                     encoding: encoding, chunkSize: chunkSize)
    }

    @Test func anchorsAndWordBoundariesDoNotMatchAtTheSearchStart() throws {
        let data = Data("foo bar\nbaz qux".utf8)
        let regex = SearchOptions(regex: true)
        // From inside "foo", ^\w+ is the next line's word, not the rest of the first one.
        #expect(try find("^\\w+", regex, in: data, from: 1) == 8..<11)
        // \b is not a boundary in the middle of a word.
        #expect(try find("\\bar", regex, in: data, from: 5) == nil)
        #expect(try find("\\bba", regex, in: data, from: 5) == 8..<10)
    }

    @Test func anchorsAndWordBoundariesDoNotMatchAtChunkBorders() throws {
        let data = Data("aabar bar\nx bar".utf8)
        let regex = SearchOptions(regex: true)
        for chunk in 1...12 {
            #expect(try find("\\bbar", regex, in: data, chunkSize: chunk) == 6..<9, "chunk \(chunk)")
            #expect(try find("^x", regex, in: data, chunkSize: chunk) == 10..<11, "chunk \(chunk)")
        }
    }

    @Test func aTextInADoubleByteEncodingIsFoundAcrossChunkBorders() throws {
        let gbk = try #require(ViewerEncoding.codePage(936))
        #expect(gbk.kind == .doubleByte)
        let text = String(repeating: "你好世界", count: 40) + "end"
        let data = try #require(gbk.encode(text)).withUnsafeBufferPointer { Data($0) }
        let needle = try #require(gbk.encode("界你")).count
        #expect(needle == 4)
        let first: Range<Int64> = 6..<10
        for chunk in [3, 5, 7, 9, 11, 33] {
            #expect(try find("界你", in: data, encoding: gbk, chunkSize: chunk) == first, "chunk \(chunk)")
            // Searching on from the second byte of a character finds the next one.
            let next = try find("界你", in: data, from: 7, encoding: gbk, chunkSize: chunk)
            #expect(next == 14..<18, "chunk \(chunk) \(String(describing: next))")
        }
        // Backwards, from a place deep in the text.
        let backwards = SearchOptions(backwards: true)
        for chunk in [3, 5, 7] {
            let before = try find("好世", backwards, in: data, from: 200, encoding: gbk, chunkSize: chunk)
            #expect(before?.lowerBound == 194, "chunk \(chunk) \(String(describing: before))")
        }
    }

    @Test func plainTextMatchingCaseIsSearchedInTheRawBytes() throws {
        let data = Data("Größe grösse GRÖSSE Größe".utf8)
        let sensitive = SearchOptions(caseSensitive: true)
        #expect(try find("Größe", sensitive, in: data) == 0..<7)
        #expect(try find("Größe", sensitive, in: data, from: 1) == 24..<31)
        #expect(try find("Größe", SearchOptions(caseSensitive: true, backwards: true), in: data, from: 31)?.lowerBound == 24)
        #expect(try find("gröSSE", sensitive, in: data) == nil)
        #expect(try find("gröSSE", in: data, from: 1)?.lowerBound == 8)
        // One byte per character.
        let latin = try #require(ViewerEncoding.codePage(1252))
        let bytes = try #require(latin.encode("über Übung über")).withUnsafeBufferPointer { Data($0) }
        #expect(try find("über", sensitive, in: bytes, from: 1, encoding: latin, chunkSize: 4) == 11..<15)
    }

    @Test func aBacktrackingExpressionCanBeCancelled() throws {
        let data = Data(String(repeating: "a", count: 40) .utf8 + Data("!".utf8))
        let pattern = try SearchPattern("(a+)+$", options: SearchOptions(regex: true), encoding: .utf8)
        let flag = CancellationFlag()
        let started = Date()
        Thread { Thread.sleep(forTimeInterval: 0.3); flag.cancel() }.start()
        let found = try ViewerSearch.find(pattern, in: DataByteSource(data), content: 0..<Int64(data.count), from: 0, backwards: false, encoding: .utf8,
                                          cancellation: flag)
        #expect(found == nil)
        #expect(Date().timeIntervalSince(started) < 20)
    }

    // MARK: Decoding

    @Test func decodingWithoutOffsetsGivesTheSameText() {
        let data = Data("Zeile 1\r\nGröße € 😀\nend".utf8)
        var with = DecodedText(), without = DecodedText()
        without.tracksOffsets = false
        ViewerEncoding.utf8.decode(data, final: true, into: &with)
        ViewerEncoding.utf8.decode(data, final: true, into: &without)
        #expect(with.units == without.units && !with.offsets.isEmpty && without.offsets.isEmpty)
        #expect(ViewerEncoding.utf8.string(from: data) == String(decoding: data, as: UTF8.self))
        #expect(ViewerEncoding.utf8.units(from: data) == with.units)
    }

    // MARK: Row index

    /// A text with every kind of line: short, empty, long, with tabs, CR, LF, CR+LF, wide characters, no final line end.
    private func sampleText(seed: UInt64, lines: Int) -> String {
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let words = ["alpha", "beta", "Größe", "日本語", "x", "tab\there", "😀", "  ", "wörd", "gamma", "delta"]
        let ends = ["\n", "\r\n", "\r", "\n"]
        var text = ""
        for _ in 0..<lines {
            switch next(10) {
            case 0: break
            case 1: text += String(repeating: "long line ", count: 5 + next(40))
            default: for _ in 0..<(1 + next(8)) { text += words[next(words.count)] + " " }
            }
            text += ends[next(ends.count)]
        }
        return text + "last line without end"
    }

    private func signature(_ document: TextDocument) throws -> [String] {
        try document.rows(from: 0, count: document.rowCount).map { "\($0.range.lowerBound)-\($0.range.upperBound) \($0.startsLine) \($0.line) \($0.text)" }
    }

    @Test func theRawByteScanFindsTheSameRowsAsDecodingEverything() throws {
        let text = sampleText(seed: 7, lines: 600)
        let utf8 = Data(text.utf8)
        let gbk = try #require(ViewerEncoding.codePage(936))
        let latin = try #require(ViewerEncoding.codePage(1252))
        let cases: [(Data, ViewerEncoding)] = [
            (utf8, .utf8), (utf8, latin), (Data(text.filter { gbk.encode(String($0)) != nil }.flatMap { gbk.encode(String($0)) ?? [] }), gbk),
            (Data(), .utf8), (Data("\n\n\n".utf8), .utf8), (Data("no line end".utf8), .utf8), (Data("a\r".utf8), .utf8), (Data("a\rb\r\n\r".utf8), .utf8),
        ]
        for (data, encoding) in cases {
            for options in [TextLayoutOptions(columns: 20, wordWrap: true), TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 4),
                            TextLayoutOptions(columns: 33, wordWrap: false), TextLayoutOptions(columns: 1000, wordWrap: true)] {
                for (segment, chunk) in [(1 << 20, 1 << 20), (700, 61), (97, 16), (4096, 1000)] {
                    var results: [[String]] = []
                    var counts: [[Int]] = []
                    for raw in [true, false] {
                        let document = TextDocument(source: DataByteSource(data), encoding: encoding, layout: .text(options))
                        document.buildIndex(parallel: segment < 1000, segmentSize: segment, chunkSize: chunk, rawScan: raw)
                        results.append(try signature(document))
                        counts.append([document.rowCount, document.lineCount])
                    }
                    #expect(counts[0] == counts[1], "counts for \(encoding.name) \(options) \(segment)/\(chunk)")
                    #expect(results[0] == results[1], "rows for \(encoding.name) \(options) \(segment)/\(chunk)")
                }
            }
        }
    }

    @Test func aFileWithoutLineEndsShowsItsStartBeforeItIsRead() throws {
        // One line of 10 MB: its rows are handed over every few megabytes while it is read.
        let data = Data(repeating: UInt8(ascii: "x"), count: 10 << 20)
        var partials: [(rows: Int, covered: Int64)] = []
        let segment = try TextRowIndex.scan(source: DataByteSource(data), content: 0..<Int64(data.count), segment: 0..<Int64(4 << 20), isFirst: true,
                                            encoding: .utf8, options: TextLayoutOptions(columns: 100, wordWrap: true), chunkSize: 1 << 20,
                                            cancellation: CancellationFlag()) { found, covered in partials.append((found.rowCount, covered)) }
        #expect(partials.count >= 2)
        #expect(zip(partials, partials.dropFirst()).allSatisfy { $0.rows < $1.rows && $0.covered < $1.covered })
        #expect(partials.first.map { $0.rows > 0 && $0.covered >= 3 << 20 } == true)
        #expect(segment.rowCount == 10 << 20 / 100 + 1 && segment.lineCount == 1)
    }

    @Test func theIndexPublishesTheFrontierSegmentAsItGoes() throws {
        let data = Data(repeating: UInt8(ascii: "y"), count: 9 << 20)
        let document = TextDocument(source: DataByteSource(data), encoding: .utf8, layout: .text(TextLayoutOptions(columns: 100, wordWrap: true)))
        let seen = Locked<[Int64]>([])
        document.buildIndex(parallel: true, segmentSize: 9 << 20, chunkSize: 1 << 20) { seen.mutate { $0.append(document.indexedThrough) } }
        let through = seen.value
        #expect(through.count >= 3 && through.first.map { $0 < Int64(data.count) } == true)
        #expect(document.isIndexComplete && document.rowCount == 9 << 20 / 100 + 1 && document.lineCount == 1)
        #expect(try document.rows(from: document.rowCount - 1, count: 1).first?.text.count == (9 << 20) % 100)
    }

    @Test func checkpointsArePacked() {
        var list = TextRowIndex.CheckpointList()
        list.append(.init(offset: 1 << 40, linesBefore: 77, startsLine: true))
        list.append(.init(offset: 5, linesBefore: 0, startsLine: false))
        #expect(list.count == 2 && list[0].offset == 1 << 40 && list[0].linesBefore == 77 && list[0].startsLine)
        #expect(list[1].offset == 5 && !list[1].startsLine)
        #expect(MemoryLayout<Int64>.stride + MemoryLayout<UInt32>.stride == 12)
    }

    @Test func aFailedReadIsRecordedAndShown() throws {
        final class Failing: ByteSource {
            let length: Int64 = 3000
            func read(at offset: Int64, count: Int) throws -> Data {
                if offset >= 1000 { throw CocoaError(.fileReadUnknown) }
                return Data(repeating: UInt8(ascii: "a"), count: min(count, 1000 - Int(offset)))
            }
        }
        let document = TextDocument(source: Failing(), encoding: .utf8, layout: .text(TextLayoutOptions(columns: 50, wordWrap: true)))
        #expect(document.readError == nil)
        document.buildIndex(parallel: false, segmentSize: 500, chunkSize: 200)
        #expect(document.readError != nil)
    }

    // MARK: HTML

    @Test func htmlIsStrippedFromUnitsAndCanBeCancelled() throws {
        let html = "<p>One &amp; two</p><script>x<y</script><a href=\"u\">l</a><!-- c --><pre> a  b </pre>"
        let expected = HTMLText.plainText(from: html)
        #expect(expected.text == "One & two\nl {u}\n a  b\n" && expected.links == ["u"])
        #expect(HTMLText.plainText(units: Array(html.utf16)) == expected)
        let flag = CancellationFlag()
        flag.cancel()
        #expect(HTMLText.plainText(units: Array(repeating: 0x61, count: 3 << 20), cancellation: flag) == nil)
    }

    @Test func htmlIsStrippedFast() {
        var html = ""
        for number in 0..<20_000 { html += "<div class=\"row\"><p>Line \(number) with <b>bold</b> &amp; text, more words to fill the line a bit.</p></div>\n" }
        let units = Array(html.utf16)
        let started = Date()
        let result = HTMLText.plainText(units: units)
        let seconds = Date().timeIntervalSince(started)
        #expect(result?.text.hasPrefix("Line 0 with bold & text") == true)
        // Debug build, a few megabytes: far from the 14 MB/s of the character-by-character version only when optimised;
        // here it just has to be sane.
        #expect(seconds < 5, "\(Double(units.count) / 1e6 / max(seconds, 1e-6)) M units/s")
    }

    // MARK: Cached remote reads

    @Test func aSmallRemoteFileIsFetchedOnceForAnyNumberOfLongReads() throws {
        final class Counting: ByteSource {
            let data = Data((0..<300_000).map { UInt8($0 % 251) })
            var length: Int64 { Int64(data.count) }
            private let lock = NSLock()
            private(set) var reads = 0
            func read(at offset: Int64, count: Int) throws -> Data {
                lock.lock()
                reads += 1
                lock.unlock()
                let lower = Int(offset), upper = min(data.count, lower + count)
                return data.subdata(in: lower..<upper)
            }
        }
        let base = Counting()
        let cached = CachedByteSource(base, blockSize: 16 << 10, capacity: 32, wholeFileLimit: 1 << 20)
        for _ in 0..<5 {
            #expect(try cached.read(at: 0, count: 1 << 20) == base.data)
            #expect(try cached.read(at: 100_000, count: 150_000) == base.data.subdata(in: 100_000..<250_000))
        }
        #expect(base.reads == 1)
        // Without the limit long reads pass through, as before.
        let plain = Counting()
        let uncached = CachedByteSource(plain, blockSize: 16 << 10, capacity: 32)
        for _ in 0..<3 { _ = try uncached.read(at: 0, count: 1 << 20) }
        #expect(plain.reads == 3)
    }

    // MARK: Temporary copies

    @Test func temporaryCopiesAreUniqueKeyedByStampAndReleased() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let flag = CancellationFlag()
        let owner = ObjectIdentifier(copies)
        let url = memory.addFile("/a/movie.mp4", "one", modified: Date(timeIntervalSince1970: 100))
        let first = try #require(copies.localURL(for: url, fileSystems: registry, owner: owner, cancellation: flag))
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        // The same stamp is the same copy.
        #expect(copies.localURL(for: url, fileSystems: registry, owner: owner, cancellation: flag) == first)
        // A changed file is copied anew, in a folder of its own.
        memory.addFile("/a/movie.mp4", "changed", modified: Date(timeIntervalSince1970: 200))
        let second = try #require(copies.localURL(for: url, fileSystems: registry, owner: owner, cancellation: flag))
        #expect(second != first && second.deletingLastPathComponent() != first.deletingLastPathComponent())
        #expect(try String(contentsOf: second, encoding: .utf8) == "changed")
        #expect(FileManager.default.fileExists(atPath: first.path))
        // A cancelled copy removes nothing that belongs to another.
        let cancelled = CancellationFlag()
        cancelled.cancel()
        let other = memory.addFile("/a/other.mp4", String(repeating: "z", count: 100))
        #expect(copies.localURL(for: other, fileSystems: registry, owner: owner, cancellation: cancelled) == nil)
        #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
        // Once released, only a couple of idle copies stay.
        for number in 0..<4 {
            let file = memory.addFile("/b/f\(number).mp4", "x\(number)")
            _ = copies.localURL(for: file, fileSystems: registry, owner: owner, cancellation: flag)
        }
        copies.release(owner: owner)
        // The files are deleted in the background.
        copies.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path))
        let root = second.deletingLastPathComponent().deletingLastPathComponent()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0
        #expect(left == TemporaryCopies.idleLimit)
        copies.removeAll()
        copies.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func leftoverFoldersOfDeadProcessesAreSwept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-sweep-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = directory.appendingPathComponent("afm-viewer-p\(getpid())-A", isDirectory: true)
        let dead = directory.appendingPathComponent("afm-viewer-p2147483000-B", isDirectory: true)
        let recentOld = directory.appendingPathComponent("afm-viewer-C", isDirectory: true)
        let other = directory.appendingPathComponent("other-folder", isDirectory: true)
        for folder in [mine, dead, recentOld, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        TemporaryCopies.sweep(in: directory)
        #expect(FileManager.default.fileExists(atPath: mine.path) && !FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: recentOld.path) && FileManager.default.fileExists(atPath: other.path))
        TemporaryCopies.sweep(in: directory, now: Date().addingTimeInterval(3 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: recentOld.path) && FileManager.default.fileExists(atPath: other.path))
    }
}

/// A value guarded by a lock, for collecting results from several threads.
private final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}
