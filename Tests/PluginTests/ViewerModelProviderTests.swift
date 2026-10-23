import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The viewer's model over a file system without any window: reading through a provider, HTML as text and
/// folder sizes.
@Suite
internal struct ViewerModelProviderTests {
    // MARK: Reading through a provider

    /// A file of these bytes in a memory file system, and a registry that knows that file system.
    private func memoryFile(_ data: Data) throws -> (registry: FileSystemRegistry, url: URL) {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        let url = memory.url("/dir/blob.bin")
        memory.createDirectory(at: memory.url("/dir"))
        let writer = try memory.write(url)
        try writer.write(data)
        try writer.close(attributes: FileAttributes())
        return (registry, url)
    }

    /// A file is read through its provider at any offset, from many threads at once, after a close too, and a
    /// missing one fails to open.
    @Test
    internal func filesAreReadThroughTheirProviderWithSeek() throws {
        // Byte `i` is `i % 251`.
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let (registry, url) = try memoryFile(data)
        let source = try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag())
        #expect(source is ProviderByteSource && source.length == 300_000)
        #expect(try source.read(at: 0, count: 10) == data.prefix(10))
        #expect(try source.read(at: 299_990, count: 100) == data.suffix(10))
        #expect(try source.read(250_000..<250_300) == data.subdata(in: 250_000..<250_300))
        #expect(try source.read(at: 400_000, count: 5).isEmpty)
        // Many threads at once, each through a reader of its own.
        var policy = CachedByteSource.Policy.standard
        (policy.blockSize, policy.capacity) = (4_096, 8)
        let cached = CachedByteSource(source, policy: policy)
        let pieces = Parallel.map(Array(0..<400)) { number -> Bool in
            let lower = (number * 7_919) % 290_000
            let length = 1 + (number * 131) % 9_000
            return (try? cached.read(at: Int64(lower), count: length)) == data.subdata(in: lower..<lower + length)
        }
        #expect(!pieces.contains(false))
        #expect(
            try cached.read(at: 299_999, count: 50) == data.suffix(1) && cached.read(at: 300_000, count: 1).isEmpty
        )
        source.close()
        #expect(try source.read(at: 5, count: 3) == data.subdata(in: 5..<8))
        let missing = try #require(URL(string: "mem:///missing.txt"))
        #expect(throws: (any Error).self) {
            try ProviderByteSource.open(missing, fileSystems: registry, cancellation: CancellationFlag())
        }
    }

    /// A text on another file system is detected, indexed, searched and shown like a local one.
    @Test
    internal func aTextOnAnotherFileSystemIsIndexedSearchedAndShown() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        var lines: [String] = []
        for number in 1...30_000 { lines.append("Zeile \(number): Größe \(number * 3)") }
        let url = memory.addFile("/texts/long.txt", lines.joined(separator: "\r\n"))
        let source = CachedByteSource(
            try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag()),
            policy: .standard
        )
        let guess = ViewerDetection.guessText(
            try source.read(at: 0, count: ViewerDetection.sampleSize),
            isWholeFile: false
        )
        #expect(guess.encoding == .utf8 && !guess.isBinary)
        let document = TextDocument(
            source: source,
            encoding: guess.encoding,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 200, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        document.buildIndex(
            parallel: true,
            scanning: TextRowIndex.ScanOptions(segmentSize: 100_000, chunkSize: 10_000, rawScan: true)
        ) {
            // Not watched here.
        }
        #expect(document.rowCount == 30_000)
        #expect(
            try document.rows(from: 29_998, count: 5, cancellation: nil).map(\.text) == [
                "Zeile 29999: Größe 89997", "Zeile 30000: Größe 90000"
            ]
        )
        let pattern = try SearchPattern("zeile 22222:", options: SearchOptions(), encoding: .utf8)
        var tuning = ViewerSearch.Tuning.standard
        tuning.chunkSize = 50_000
        let found = try #require(
            try ViewerSearch.find(
                ViewerSearch.Request(pattern: pattern, start: 0, backwards: false),
                in: ViewerSearch.Subject(source: source, content: document.content, encoding: .utf8, boundaries: nil),
                tuning: tuning,
                cancellation: CancellationFlag()
            ) { _ in
                // Not watched here.
            }
        )
        let row = try #require(try document.row(containing: found.lowerBound, cancellation: nil))
        #expect(row == 22_221)
        #expect(try document.rows(from: row, count: 1, cancellation: nil).first?.range.lowerBound == found.lowerBound)
    }

    // MARK: HTML and folders

    /// HTML becomes text with its links in braces, entities decoded and preformatted text kept.
    @Test
    internal func htmlBecomesTextWithItsLinks() {
        let html = """
            <html><head><title>Page</title><style>p { color: red }</style><script>alert("<b>")</script></head>
            <body><h1>Head&nbsp;line</h1><p>First   paragraph
            with a <a href="other.html">relative link</a> and an <A HREF='https://example.com/?a=1&amp;b=2'>absolute</A> one.</p>
            <!-- <p>hidden</p> --><ul><li>one &lt;1&gt;</li><li>two &#8364; &#x41;</li></ul><pre>  kept
              as is</pre></body></html>
            """
        let result = HTMLText.plainText(from: html, linkBraces: true)
        #expect(result.links == ["other.html", "https://example.com/?a=1&b=2"])
        #expect(
            result.text == """
                Page
                Head line
                First paragraph with a relative link {other.html} and an absolute {https://example.com/?a=1&b=2} one.
                one <1>
                two € A
                  kept
                  as is

                """
        )
        #expect(HTMLText.plainText(from: "<a href=x>y</a>", linkBraces: false).text == "y x\n")
        #expect(HTMLText.url(from: "{https://example.com/a}")?.absoluteString == "https://example.com/a")
        #expect(
            HTMLText.url(from: "www.example.com")?.absoluteString == "https://www.example.com"
                && HTMLText.url(from: "plain words") == nil
        )
    }

    /// Folder sizes that would leave the range of a number stop at its end.
    @Test
    internal func folderSizesThatLeaveTheRangeOfANumberStopAtItsEnd() {
        let sum =
            FolderSummary(files: 1, folders: 0, bytes: .max - 1) + FolderSummary(files: 1, folders: 0, bytes: 10)
        #expect(sum == FolderSummary(files: 2, folders: 0, bytes: .max))
    }

    /// Folders are summed up through their file system, and a cancelled sum is empty.
    @Test
    internal func foldersAreSummedUpThroughTheirFileSystem() {
        let memory = MemoryFileSystem()
        memory.addFile("/top/a.txt", "12345")
        memory.addFile("/top/sub/b.txt", "123")
        memory.addFile("/top/sub/deep/c.txt", "1")
        memory.addDirectory("/top/empty")
        let summary = FolderSummary.measure(
            memory.url("/top"),
            provider: memory,
            cancellation: CancellationFlag(),
            limit: nil
        )
        #expect(summary == FolderSummary(files: 3, folders: 3, bytes: 9))
        #expect(summary.text == "3 files, 3 folders, 9 bytes (9 b)")
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            FolderSummary.measure(memory.url("/top"), provider: memory, cancellation: cancelled, limit: nil)
                == FolderSummary()
        )
    }
}
