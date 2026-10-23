import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// Fixes to the row index found in review: the raw-byte row scan, partial results of a huge line, the frontier
/// published while indexing, packed checkpoints and failed reads.
@Suite
internal struct ViewerFixRowIndexTests {
    /// A text with every kind of line: short, empty, long, with tabs, CR, LF, CR+LF, wide characters, no final line
    /// end.
    private func sampleText(seed: UInt64, lines: Int) -> String {
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let words = ["alpha", "beta", "Größe", "日本語", "x", "tab\there", "😀", "  ", "wörd", "gamma", "delta"]
        let ends = ["\n", "\r\n", "\r", "\n"]
        var text = ""
        for _ in 0..<lines {
            switch next(10) {
            case 0:
                break

            case 1:
                text += String(repeating: "long line ", count: 5 + next(40))

            default:
                for _ in 0..<(1 + next(8)) { text += words[next(words.count)] + " " }
            }
            text += ends[next(ends.count)]
        }
        return text + "last line without end"
    }

    /// The raw byte scan finds the rows and lines that decoding everything finds, in UTF-8, a code page and GBK, for
    /// every layout and every segment and chunk size.
    @Test
    internal func theRawByteScanFindsTheSameRowsAsDecodingEverything() throws {
        let text = sampleText(seed: 7, lines: 600)
        let utf8 = Data(text.utf8)
        let gbk = try #require(ViewerEncoding.codePage(936))
        let latin = try #require(ViewerEncoding.codePage(1_252))
        let cases: [(Data, ViewerEncoding)] = [
            (utf8, .utf8), (utf8, latin),
            (Data(text.flatMap { (try? gbk.encode(String($0))) ?? [] }), gbk),
            (Data(), .utf8), (Data("\n\n\n".utf8), .utf8), (Data("no line end".utf8), .utf8),
            (Data("a\r".utf8), .utf8), (Data("a\rb\r\n\r".utf8), .utf8)
        ]
        for (data, encoding) in cases {
            for options in [
                TextLayoutOptions(columns: 20, wordWrap: true, tabWidth: 8),
                TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 4),
                TextLayoutOptions(columns: 33, wordWrap: false, tabWidth: 8),
                TextLayoutOptions(columns: 1_000, wordWrap: true, tabWidth: 8)
            ] {
                for (segment, chunk) in [(1 << 20, 1 << 20), (700, 61), (97, 16), (4_096, 1_000)] {
                    var results: [[String]] = []
                    var counts: [[Int]] = []
                    for raw in [true, false] {
                        let document = TextDocument(
                            source: DataByteSource(data),
                            encoding: encoding,
                            bomLength: 0,
                            layout: .text(options),
                            reusing: nil
                        )
                        document.buildIndex(
                            parallel: segment < 1_000,
                            scanning: TextRowIndex.ScanOptions(segmentSize: segment, chunkSize: chunk, rawScan: raw)
                        ) {
                            // Not watched here.
                        }
                        results.append(try document.signature())
                        counts.append([document.rowCount, document.lineCount])
                    }
                    #expect(counts[0] == counts[1], "counts for \(encoding.name) \(options) \(segment)/\(chunk)")
                    #expect(results[0] == results[1], "rows for \(encoding.name) \(options) \(segment)/\(chunk)")
                }
            }
        }
    }

    /// A line of 10 MB hands its rows over every few megabytes while it is read, each time more of them.
    @Test
    internal func aFileWithoutLineEndsShowsItsStartBeforeItIsRead() throws {
        // One line of 10 MB: its rows are handed over every few megabytes while it is read.
        let data = Data(repeating: UInt8(ascii: "x"), count: 10 << 20)
        var partials: [(rows: Int, covered: Int64)] = []
        let segment = try TextRowIndex.scan(
            TextRowIndex.Input(
                source: DataByteSource(data),
                content: 0..<Int64(data.count),
                encoding: .utf8,
                options: TextLayoutOptions(columns: 100, wordWrap: true, tabWidth: 8)
            ),
            TextRowIndex.SegmentJob(
                segment: 0..<Int64(4 << 20),
                isFirst: true,
                lineStart: nil,
                partial: { found, covered in partials.append((found.rowCount, covered)) },
                changed: nil
            ),
            scanning: TextRowIndex.ScanOptions(segmentSize: 4 << 20, chunkSize: 1 << 20, rawScan: true),
            cancellation: CancellationFlag()
        )
        #expect(partials.count >= 2)
        #expect(zip(partials, partials.dropFirst()).allSatisfy { $0.rows < $1.rows && $0.covered < $1.covered })
        #expect(partials.first.map { $0.rows > 0 && $0.covered >= 3 << 20 } == true)
        #expect(segment.rowCount == 10 << 20 / 100 + 1 && segment.lineCount == 1)
    }

    /// While one big segment is indexed, the bytes indexed so far are published as they grow.
    @Test
    internal func theIndexPublishesTheFrontierSegmentAsItGoes() throws {
        let data = Data(repeating: UInt8(ascii: "y"), count: 9 << 20)
        let document = TextDocument(
            source: DataByteSource(data),
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 100, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        let seen = ViewerAdoptBox<[Int64]>([])
        document.buildIndex(
            parallel: true,
            scanning: TextRowIndex.ScanOptions(segmentSize: 9 << 20, chunkSize: 1 << 20, rawScan: true)
        ) {
            seen.mutate { offsets in offsets.append(document.indexedThrough) }
        }
        let through = seen.value
        #expect(through.count >= 3 && through.first.map { $0 < Int64(data.count) } == true)
        #expect(document.isIndexComplete && document.rowCount == 9 << 20 / 100 + 1 && document.lineCount == 1)
        #expect(
            try document.rows(from: document.rowCount - 1, count: 1, cancellation: nil).first?.text.count == (9 << 20)
                % 100
        )
    }

    /// A checkpoint keeps its offset, its lines before and whether it starts a line, packed in 12 bytes.
    @Test
    internal func checkpointsArePacked() {
        var list = TextRowIndex.CheckpointList()
        list.append(.init(offset: 1 << 40, linesBefore: 77, startsLine: true))
        list.append(.init(offset: 5, linesBefore: 0, startsLine: false))
        #expect(list.count == 2 && list[0].offset == 1 << 40 && list[0].linesBefore == 77 && list[0].startsLine)
        #expect(list[1].offset == 5 && !list[1].startsLine)
        #expect(MemoryLayout<Int64>.stride + MemoryLayout<UInt32>.stride == 12)
    }

    /// A read that fails while indexing is recorded as the document's read error.
    @Test
    internal func aFailedReadIsRecordedAndShown() {
        final class Failing: ByteSource {
            let length: Int64 = 3_000

            func read(at offset: Int64, count: Int) throws -> Data {
                if offset >= 1_000 { throw CocoaError(.fileReadUnknown) }
                return Data(repeating: UInt8(ascii: "a"), count: min(count, 1_000 - Int(offset)))
            }

            deinit {
                // Nothing to release.
            }
        }
        let document = TextDocument(
            source: Failing(),
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 50, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        #expect(document.readError == nil)
        document.buildIndex(
            parallel: false,
            scanning: TextRowIndex.ScanOptions(segmentSize: 500, chunkSize: 200, rawScan: true)
        ) {
            // Not watched here.
        }
        #expect(document.readError != nil)
    }
}
