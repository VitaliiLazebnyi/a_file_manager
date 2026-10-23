import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Fixes to the viewer found in review: search context at chunk borders and in double-byte
/// texts, decoding without offsets, HTML as text, cached remote reads and temporary copies.
@Suite
internal struct ViewerFixTests {
    // MARK: Search

    /// The first place the viewer's search finds `text` in the bytes from `start` on (or before it, backwards).
    private func find(
        _ text: String,
        _ options: SearchOptions,
        in data: Data,
        from start: Int64 = 0,
        encoding: ViewerEncoding = .utf8,
        chunkSize: Int = 1 << 20
    ) throws -> Range<Int64>? {
        let pattern = try SearchPattern(text, options: options, encoding: encoding)
        var tuning = ViewerSearch.Tuning.standard
        tuning.chunkSize = chunkSize
        return try ViewerSearch.find(
            ViewerSearch.Request(pattern: pattern, start: start, backwards: options.backwards),
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

    /// `^` and `\b` match only where the text has a line start or a word boundary, not where the search starts.
    @Test
    internal func anchorsAndWordBoundariesDoNotMatchAtTheSearchStart() throws {
        let data = Data("foo bar\nbaz qux".utf8)
        let regex = SearchOptions(regex: true)
        // From inside "foo", ^\w+ is the next line's word, not the rest of the first one.
        #expect(try find("^\\w+", regex, in: data, from: 1) == 8..<11)
        // \b is not a boundary in the middle of a word.
        #expect(try find("\\bar", regex, in: data, from: 5) == nil)
        #expect(try find("\\bba", regex, in: data, from: 5) == 8..<10)
    }

    /// `^` and `\b` do not match at a chunk border, whatever the chunk size.
    @Test
    internal func anchorsAndWordBoundariesDoNotMatchAtChunkBorders() throws {
        let data = Data("aabar bar\nx bar".utf8)
        let regex = SearchOptions(regex: true)
        for chunk in 1...12 {
            #expect(try find("\\bbar", regex, in: data, chunkSize: chunk) == 6..<9, "chunk \(chunk)")
            #expect(try find("^x", regex, in: data, chunkSize: chunk) == 10..<11, "chunk \(chunk)")
        }
    }

    /// A GBK text is found across chunk borders, from the second byte of a character on, and backwards.
    @Test
    internal func aTextInADoubleByteEncodingIsFoundAcrossChunkBorders() throws {
        let gbk = try #require(ViewerEncoding.codePage(936))
        #expect(gbk.kind == .doubleByte)
        let text = String(repeating: "你好世界", count: 40) + "end"
        let data = try gbk.encode(text).withUnsafeBufferPointer { Data($0) }
        let needle = try gbk.encode("界你").count
        #expect(needle == 4)
        let first: Range<Int64> = 6..<10
        for chunk in [3, 5, 7, 9, 11, 33] {
            #expect(
                try find("界你", SearchOptions(), in: data, encoding: gbk, chunkSize: chunk) == first,
                "chunk \(chunk)"
            )
            // Searching on from the second byte of a character finds the next one.
            let next = try find("界你", SearchOptions(), in: data, from: 7, encoding: gbk, chunkSize: chunk)
            #expect(next == 14..<18, "chunk \(chunk) \(String(describing: next))")
        }
        // Backwards, from a place deep in the text.
        let backwards = SearchOptions(backwards: true)
        for chunk in [3, 5, 7] {
            let before = try find("好世", backwards, in: data, from: 200, encoding: gbk, chunkSize: chunk)
            #expect(before?.lowerBound == 194, "chunk \(chunk) \(String(describing: before))")
        }
    }

    /// A case-sensitive search finds the same bytes forward and backward, in UTF-8 and in a single-byte code page.
    @Test
    internal func plainTextMatchingCaseIsSearchedInTheRawBytes() throws {
        let data = Data("Größe grösse GRÖSSE Größe".utf8)
        let sensitive = SearchOptions(caseSensitive: true)
        #expect(try find("Größe", sensitive, in: data) == 0..<7)
        #expect(try find("Größe", sensitive, in: data, from: 1) == 24..<31)
        #expect(
            try find("Größe", SearchOptions(caseSensitive: true, backwards: true), in: data, from: 31)?.lowerBound == 24
        )
        #expect(try find("gröSSE", sensitive, in: data) == nil)
        #expect(try find("gröSSE", SearchOptions(), in: data, from: 1)?.lowerBound == 8)
        // One byte per character.
        let latin = try #require(ViewerEncoding.codePage(1_252))
        let bytes = try latin.encode("über Übung über").withUnsafeBufferPointer { Data($0) }
        #expect(try find("über", sensitive, in: bytes, from: 1, encoding: latin, chunkSize: 4) == 11..<15)
    }

    /// A regular expression that backtracks without end stops when its flag is set, and finds nothing.
    @Test
    internal func aBacktrackingExpressionCanBeCancelled() throws {
        let data = Data(String(repeating: "a", count: 40).utf8 + Data("!".utf8))
        let pattern = try SearchPattern("(a+)+$", options: SearchOptions(regex: true), encoding: .utf8)
        let flag = CancellationFlag()
        let started = Date()
        Thread {
            Thread.sleep(forTimeInterval: 0.3)
            flag.cancel()
        }
        .start()
        let found = try ViewerSearch.find(
            ViewerSearch.Request(pattern: pattern, start: 0, backwards: false),
            in: ViewerSearch.Subject(
                source: DataByteSource(data),
                content: 0..<Int64(data.count),
                encoding: .utf8,
                boundaries: nil
            ),
            tuning: .standard,
            cancellation: flag
        ) { _ in
            // Not watched here.
        }
        #expect(found == nil)
        #expect(Date().timeIntervalSince(started) < 20)
    }

    // MARK: Decoding

    /// Decoding without offsets gives the same units, and the text helpers give what Foundation gives.
    @Test
    internal func decodingWithoutOffsetsGivesTheSameText() {
        let data = Data("Zeile 1\r\nGröße € 😀\nend".utf8)
        var with = DecodedText()
        var without = DecodedText()
        without.tracksOffsets = false
        ViewerEncoding.utf8.decode(data, final: true, into: &with)
        ViewerEncoding.utf8.decode(data, final: true, into: &without)
        #expect(with.units == without.units && !with.offsets.isEmpty && without.offsets.isEmpty)
        #expect(ViewerEncoding.utf8.string(from: data) == String(bytes: data, encoding: .utf8))
        #expect(ViewerEncoding.utf8.units(from: data) == with.units)
    }

    // MARK: HTML

    /// HTML from units gives the text and links of HTML from a string, and a set flag ends a long page with nothing.
    @Test
    internal func htmlIsStrippedFromUnitsAndCanBeCancelled() {
        let html = "<p>One &amp; two</p><script>x<y</script><a href=\"u\">l</a><!-- c --><pre> a  b </pre>"
        let expected = HTMLText.plainText(from: html, linkBraces: true)
        #expect(expected.text == "One & two\nl {u}\n a  b\n" && expected.links == ["u"])
        #expect(HTMLText.plainText(units: Array(html.utf16), linkBraces: true, cancellation: nil) == expected)
        let flag = CancellationFlag()
        flag.cancel()
        #expect(
            HTMLText.plainText(units: Array(repeating: 0x61, count: 3 << 20), linkBraces: true, cancellation: flag)
                == nil
        )
    }

    /// A page of 20,000 lines of HTML is made text in a few seconds even in a debug build.
    @Test
    internal func htmlIsStrippedFast() {
        var html = ""
        for number in 0..<20_000 {
            html +=
                "<div class=\"row\"><p>Line \(number) with <b>bold</b> &amp; text, "
                + "more words to fill the line a bit.</p></div>\n"
        }
        let units = Array(html.utf16)
        let started = Date()
        let result = HTMLText.plainText(units: units, linkBraces: true, cancellation: nil)
        let seconds = Date().timeIntervalSince(started)
        #expect(result?.text.hasPrefix("Line 0 with bold & text") == true)
        // Debug build, a few megabytes: far from the 14 MB/s of the character-by-character version only when optimised;
        // here it just has to be sane.
        #expect(seconds < 5, "\(Double(units.count) / 1e6 / max(seconds, 1e-6)) M units/s")
    }

    // MARK: Cached remote reads

    /// A file below the whole-file limit is fetched once for any number of long reads; without the limit they pass
    /// through.
    @Test
    internal func aSmallRemoteFileIsFetchedOnceForAnyNumberOfLongReads() throws {
        // Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
        final class Counting: ByteSource, @unchecked Sendable {
            let data = Data((0..<300_000).map { UInt8($0 % 251) })
            var length: Int64 { Int64(data.count) }
            private let lock = NSLock()
            private(set) var reads = 0

            func read(at offset: Int64, count: Int) -> Data {
                lock.lock()
                reads += 1
                lock.unlock()
                let lower = Int(offset)
                let upper = min(data.count, lower + count)
                return data.subdata(in: lower..<upper)
            }

            deinit {
                // Nothing to release.
            }
        }
        let base = Counting()
        var policy = CachedByteSource.Policy.standard
        (policy.blockSize, policy.capacity, policy.wholeFileLimit) = (16 << 10, 32, 1 << 20)
        let cached = CachedByteSource(base, policy: policy)
        for _ in 0..<5 {
            #expect(try cached.read(at: 0, count: 1 << 20) == base.data)
            #expect(try cached.read(at: 100_000, count: 150_000) == base.data.subdata(in: 100_000..<250_000))
        }
        #expect(base.reads == 1)
        // Without the limit long reads pass through, as before.
        let plain = Counting()
        policy.wholeFileLimit = 0
        let uncached = CachedByteSource(plain, policy: policy)
        for _ in 0..<3 { _ = try uncached.read(at: 0, count: 1 << 20) }
        #expect(plain.reads == 3)
    }

    // MARK: Temporary copies

    /// A temporary copy is made once per modification stamp, a cancelled one removes nothing of another, and released
    /// copies are deleted but for a few idle ones.
    @Test
    internal func temporaryCopiesAreUniqueKeyedByStampAndReleased() throws {
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
        #expect(
            FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path)
        )
        // Once released, only a couple of idle copies stay.
        for number in 0..<4 {
            let file = memory.addFile("/b/f\(number).mp4", "x\(number)")
            _ = copies.localURL(for: file, fileSystems: registry, owner: owner, cancellation: flag)
        }
        copies.release(owner: owner)
        // The files are deleted in the background.
        copies.waitForCleanup()
        #expect(
            !FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path)
        )
        let root = second.deletingLastPathComponent().deletingLastPathComponent()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0
        #expect(left == TemporaryCopies.idleLimit)
        copies.removeAll()
        copies.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// The sweep removes the copy folders of dead processes at once and old ones of unknown processes after a
    /// while, and leaves the rest.
    @Test
    internal func leftoverFoldersOfDeadProcessesAreSwept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-sweep-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = directory.appendingPathComponent("afm-viewer-p\(getpid())-A", isDirectory: true)
        let dead = directory.appendingPathComponent("afm-viewer-p2147483000-B", isDirectory: true)
        let recentOld = directory.appendingPathComponent("afm-viewer-C", isDirectory: true)
        let other = directory.appendingPathComponent("other-folder", isDirectory: true)
        for folder in [mine, dead, recentOld, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        TemporaryCopies.sweep(in: directory)
        #expect(FileManager.default.fileExists(atPath: mine.path) && !FileManager.default.fileExists(atPath: dead.path))
        #expect(
            FileManager.default.fileExists(atPath: recentOld.path) && FileManager.default.fileExists(atPath: other.path)
        )
        TemporaryCopies.sweep(in: directory, now: Date().addingTimeInterval(3 * 86_400))
        #expect(
            !FileManager.default.fileExists(atPath: recentOld.path)
                && FileManager.default.fileExists(atPath: other.path)
        )
    }
}
