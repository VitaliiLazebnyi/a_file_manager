import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// A new layout of a text takes over what the old layout's index found, where that is still true.
@Suite
internal struct ViewerAdoptReuseTests {
    /// Segments of 4,000 bytes, read in chunks of 1 MB, raw where that works.
    private static let smallScan = TextRowIndex.ScanOptions(segmentSize: 4_000, chunkSize: 1 << 20, rawScan: true)

    /// Lays the source's UTF-8 text out in the columns, word-wrapped, taking over what it can of `previous`, and
    /// indexes it in segments of 40,000 bytes.
    private func laidOut(
        _ source: any ByteSource,
        columns: Int,
        reusing previous: TextDocument?,
        parallel: Bool
    ) -> TextDocument {
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: columns, wordWrap: true, tabWidth: 8)),
            reusing: previous
        )
        document.buildIndex(
            parallel: parallel,
            scanning: TextRowIndex.ScanOptions(segmentSize: 40_000, chunkSize: 1 << 20, rawScan: true)
        ) {
            // Not watched here.
        }
        return document
    }

    /// A layout takes over the segments whose lines fit both its width and the other one's without a wrap, and finds
    /// the same rows as a layout made from nothing.
    @Test
    internal func aWiderLayoutTakesOverTheSegmentsWhoseLinesStillFitInOneRow() throws {
        // Eight segments of 40 KB: the line of 300 characters is in the fifth, all others are short.
        var lines: [String] = []
        var size = 0
        var number = 0
        while size < 320_000 {
            let line =
                number == 4_000 ? String(repeating: "wide ", count: 60) : "short line \(number) with some text in it"
            lines.append(line)
            size += line.utf8.count + 1
            number += 1
        }
        let data = Data(lines.joined(separator: "\n").utf8)
        let source = DataByteSource(data)
        let narrow = laidOut(source, columns: 100, reusing: nil, parallel: false)
        #expect(narrow.segmentsReused == 0)
        let segments = (data.count + 39_999) / 40_000
        // 100 → 400 columns: every line fits both, so everything is taken over.
        let wide = laidOut(source, columns: 400, reusing: narrow, parallel: true)
        #expect(wide.segmentsReused == segments - 1, "the line of 300 characters did not fit 100 columns")
        let fresh = laidOut(source, columns: 400, reusing: nil, parallel: true)
        #expect(fresh.segmentsReused == 0)
        #expect(wide.rowCount == fresh.rowCount && wide.lineCount == fresh.lineCount && wide.rowCount == lines.count)
        #expect(try wide.signature() == fresh.signature())
        // Back to 100 columns from the wide one: the segment with the long line is read again.
        let back = laidOut(source, columns: 100, reusing: wide, parallel: false)
        #expect(back.segmentsReused == segments - 1 && back.rowCount == narrow.rowCount)
        #expect(try back.signature() == narrow.signature())
        // 50 columns: lines of 41 characters still fit, so that is taken over too; 30: they do not.
        let fifty = laidOut(source, columns: 50, reusing: back, parallel: false)
        #expect(fifty.segmentsReused == segments - 1)
        let thirty = laidOut(source, columns: 30, reusing: fifty, parallel: false)
        let thirtyFresh = laidOut(source, columns: 30, reusing: nil, parallel: false)
        // (The 17 bytes behind the eighth segment hold no line start: nothing to read.)
        #expect(thirty.segmentsReused <= 1 && thirty.rowCount == thirtyFresh.rowCount && thirty.rowCount > lines.count)
        #expect(try thirty.signature() == thirtyFresh.signature())
    }

    /// A text of `source` in `encoding`, after a byte order mark of `bom` bytes, laid out with `options` (taking over
    /// what it can from `previous`), its rows found in segments of 4,000 bytes.
    private func smallSegments(
        _ source: any ByteSource,
        _ encoding: ViewerEncoding,
        _ options: TextLayoutOptions,
        bom: Int,
        reusing previous: TextDocument?
    ) -> TextDocument {
        let document = TextDocument(
            source: source,
            encoding: encoding,
            bomLength: bom,
            layout: .text(options),
            reusing: previous
        )
        document.buildIndex(parallel: false, scanning: Self.smallScan) {
            // Not watched here.
        }
        return document
    }

    /// Nothing is taken over from the index of another source, encoding, tab width or byte order mark, nor from an
    /// index that was cancelled.
    @Test
    internal func nothingIsTakenOverFromAnotherTextAnotherEncodingOrAnotherTabWidth() {
        let data = Data((0..<2_000).map { "line \($0)" }.joined(separator: "\n").utf8)
        let source = DataByteSource(data)
        let narrow = TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)
        let first = smallSegments(source, .utf8, narrow, bom: 0, reusing: nil)
        func relaid(_ source: any ByteSource, _ encoding: ViewerEncoding, _ options: TextLayoutOptions, bom: Int)
            -> TextDocument
        {
            smallSegments(source, encoding, options, bom: bom, reusing: first)
        }
        let wide = TextLayoutOptions(columns: 200, wordWrap: true, tabWidth: 8)
        #expect(relaid(source, .utf8, wide, bom: 0).segmentsReused > 0)
        // The same bytes in another source are not known to be the same.
        #expect(relaid(DataByteSource(data), .utf8, wide, bom: 0).segmentsReused == 0)
        #expect(
            relaid(source, .utf8, TextLayoutOptions(columns: 200, wordWrap: true, tabWidth: 4), bom: 0)
                .segmentsReused == 0
        )
        #expect(relaid(source, .ansi, wide, bom: 0).segmentsReused == 0)
        #expect(relaid(source, .utf8, wide, bom: 3).segmentsReused == 0)
        #expect(relaid(source, .utf8, wide, bom: 0).segmentsReused > 0)
        // An index that was cancelled is not a basis.
        let cut = TextDocument(source: source, encoding: .utf8, bomLength: 0, layout: .text(narrow), reusing: nil)
        cut.cancellation.cancel()
        cut.buildIndex(parallel: false, scanning: Self.smallScan) {
            // Not watched here.
        }
        let after = smallSegments(source, .utf8, wide, bom: 0, reusing: cut)
        #expect(after.segmentsReused == 0 && after.rowCount == 2_000)
    }

    /// A scanned segment records its widest line in columns, or that a line was wider than the layout.
    @Test
    internal func aSegmentRecordsTheWidestLineOrThatALineWasCut() throws {
        func widest(_ text: String, columns: Int) throws -> Int {
            let data = Data(text.utf8)
            return
                try TextRowIndex.scan(
                    TextRowIndex.Input(
                        source: DataByteSource(data),
                        content: 0..<Int64(data.count),
                        encoding: .utf8,
                        options: TextLayoutOptions(columns: columns, wordWrap: true, tabWidth: 8)
                    ),
                    TextRowIndex.SegmentJob(segment: 0..<Int64(data.count), isFirst: true),
                    scanning: .standard,
                    cancellation: CancellationFlag()
                )
                .widest
        }
        #expect(try widest("ab\nabcdef\nabc", columns: 80) == 6)
        #expect(try widest("a\tb\n", columns: 80) == 9)
        #expect(try widest("\n\n\n\n\n\n", columns: 80) == 0)
        #expect(try widest(String(repeating: "x", count: 100), columns: 80) == .max)
        #expect(try widest("ab\r\ncd\r\n", columns: 80) == 2)
    }
}
