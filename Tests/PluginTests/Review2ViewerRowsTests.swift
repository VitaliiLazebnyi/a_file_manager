import Foundation
import Testing

@testable import ViewerPlugin

/// Review round 2, the row index: lines longer than a segment, files that become shorter or
/// unreadable while they are indexed, and rows that are never cut in front of a mark.
@Suite
internal struct Review2ViewerRowsTests {
    // MARK: Files that change

    /// A source of `length` bytes that has become shorter: it gives only the first `available`.
    private final class Shrunk: ByteSource {
        let length: Int64
        let available: Int

        init(length: Int64, available: Int) {
            self.length = length
            self.available = available
        }

        func read(at offset: Int64, count: Int) -> Data {
            guard offset < Int64(available) else {
                return Data()
            }
            return Data(repeating: UInt8(ascii: "a"), count: min(count, available - Int(offset)))
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A source that cannot be read at some places.
    private final class Gappy: ByteSource {
        let data: Data
        let unreadable: Range<Int64>
        var length: Int64 { Int64(data.count) }

        init(_ data: Data, unreadable: Range<Int64>) {
            self.data = data
            self.unreadable = unreadable
        }

        func read(at offset: Int64, count: Int) throws -> Data {
            if unreadable.contains(offset) { throw CocoaError(.fileReadUnknown) }
            let lower = Int(min(offset, length))
            let upper = min(data.count, lower + count)
            return data.subdata(in: lower..<upper)
        }

        deinit {
            // Nothing to release.
        }
    }

    private func document(
        _ data: Data,
        columns: Int,
        segment: Int,
        chunk: Int,
        wrap: Bool = true,
        parallel: Bool = false
    ) -> TextDocument {
        indexed(
            DataByteSource(data),
            TextLayoutOptions(columns: columns, wordWrap: wrap, tabWidth: 8),
            scanning: TextRowIndex.ScanOptions(segmentSize: segment, chunkSize: chunk, rawScan: true),
            parallel: parallel
        )
    }

    /// The UTF-8 text of `source` laid out with `options`, its rows found as `scanning` says.
    internal func indexed(
        _ source: any ByteSource,
        _ options: TextLayoutOptions,
        scanning: TextRowIndex.ScanOptions,
        parallel: Bool
    ) -> TextDocument {
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(options),
            reusing: nil
        )
        document.buildIndex(parallel: parallel, scanning: scanning) {
            // Not watched here.
        }
        return document
    }

    // MARK: Segment.thin

    /// A segment with more checkpoints than bytes is thinned to one checkpoint instead of trapping.
    @Test
    internal func aSegmentWithMoreCheckpointsThanBytesIsThinnedAndDoesNotTrap() {
        // Direct call: five checkpoints over four bytes (the overflow of `step *= 2` of review 2).
        var list = TextRowIndex.CheckpointList()
        for number in 0..<5 { list.append(.init(offset: Int64(number), linesBefore: 0, startsLine: number == 0)) }
        var segment = TextRowIndex.Segment()
        segment.checkpoints = list
        segment.thin(spanning: 4)
        #expect(segment.checkpoints.count == 1 && segment.stride == TextRowIndex.stride * 8)
        // A span of zero or less is a span of one byte.
        var other = TextRowIndex.Segment()
        other.checkpoints = list
        other.thin(spanning: 0)
        #expect(other.checkpoints.count == 1)
        other.thin(spanning: -5)
        #expect(other.checkpoints.count == 1)
    }

    /// The fuzzer's reproducer, a one-column line in tiny segments, is indexed in full with one row per byte.
    @Test
    internal func theReproducerOfTheFuzzerIndexes() throws {
        // 66 bytes in one line, one column wide, segments of one byte: two checkpoints for a
        // one-byte segment (rows-thin-overflow.bin).
        let data = Data(repeating: UInt8(ascii: "q"), count: 66)
        for (segment, chunk) in [(1, 16), (2, 16), (7, 16), (64, 20)] {
            let index = document(data, columns: 1, segment: segment, chunk: chunk)
            #expect(index.isIndexComplete && index.readError == nil)
            #expect(index.rowCount == 66 && index.lineCount == 1, "segment \(segment)")
            let rows = try index.rows(from: 0, count: 66, cancellation: nil)
            #expect(rows.map(\.text) == Array(repeating: "q", count: 66))
        }
    }

    /// A line of 6 MB keeps about one checkpoint per 4 KB, and each of its rows is found where it is.
    @Test
    internal func aGiantLineKeepsFewCheckpointsAndEveryRowCanBeFound() throws {
        // A line of 6 MB in segments of 16 KB: all its rows belong to the first segment.
        let size = 6 << 20
        var bytes = Data(count: size)
        for index in 0..<size { bytes[index] = UInt8(ascii: "a") + UInt8(index % 26) }
        let columns = 20
        let index = document(bytes, columns: columns, segment: 16 << 10, chunk: 1 << 16, parallel: true)
        #expect(
            index.isIndexComplete && index.rowCount == size / columns + (size.isMultiple(of: columns) ? 0 : 1)
                && index.lineCount == 1
        )
        // About one checkpoint per 4 KB of the line, not one per 64 rows (1,280 bytes).
        let bound = size / TextRowIndex.minimumCheckpointDistance * 2 + 8
        #expect(index.checkpointCount <= bound, "checkpoints \(index.checkpointCount)")
        for row in [0, 1, 63, 64, 65, 4_095, 123_456, index.rowCount - 1] {
            let found = try #require(try index.rows(from: row, count: 1, cancellation: nil).first)
            let lower = row * columns
            #expect(found.range == Int64(lower)..<Int64(min(size, lower + columns)), "row \(row)")
            #expect(found.text == String(bytes: bytes[lower..<min(size, lower + columns)], encoding: .utf8))
            #expect(try index.row(containing: Int64(lower + 3), cancellation: nil) == row)
        }
    }

    /// Thinning leaves a segment no more checkpoints than the limit, with a wider stride.
    @Test
    internal func aSegmentNeverHoldsMoreCheckpointsThanTheLimit() {
        var list = TextRowIndex.CheckpointList()
        let total = TextRowIndex.maximumCheckpoints * 4
        for number in 0..<total { list.append(.init(offset: Int64(number) * 100, linesBefore: 0, startsLine: true)) }
        var segment = TextRowIndex.Segment()
        segment.checkpoints = list
        // The checkpoints are far apart already (100 bytes... no: 100 < 4096, so the distance rule thins too).
        segment.thin(spanning: Int64(total) * 100_000)
        #expect(segment.checkpoints.count <= TextRowIndex.maximumCheckpoints)
        #expect(segment.stride >= TextRowIndex.stride * 4)
    }

    /// A copy of a chunked checkpoint list stays as it was while the original grows, and thinning keeps every n-th one.
    @Test
    internal func aChunkedCheckpointListKeepsACopyUnchangedWhileTheOriginalGrows() {
        var list = TextRowIndex.CheckpointList()
        for number in 0..<9_000 {
            list.append(.init(offset: Int64(number) * 3, linesBefore: number, startsLine: number.isMultiple(of: 2)))
        }
        let copy = list
        for number in 9_000..<20_000 {
            list.append(.init(offset: Int64(number) * 3, linesBefore: number, startsLine: number.isMultiple(of: 2)))
        }
        #expect(copy.count == 9_000 && list.count == 20_000)
        for number in [0, 1, 4_095, 4_096, 4_097, 8_191, 8_999] {
            #expect(
                copy[number].offset == Int64(number) * 3 && copy[number].linesBefore == number
                    && copy[number].startsLine == number.isMultiple(of: 2)
            )
        }
        #expect(list[19_999].linesBefore == 19_999 && list[9_000].offset == 27_000)
        let thinned = list.thinned(every: 7)
        #expect(thinned.count == 2_858 && thinned[1].offset == 21 && thinned[2_857].linesBefore == 19_999)
    }

    /// Checkpoints thinned during the scan give the same rows and line count for every segment size.
    @Test
    internal func thinningWhileScanningGivesTheRowsOfScanningThenThinning() throws {
        // The checkpoints are thinned during the scan (every 2,048): rows come out the same
        // whatever the segment size, and the lines are counted right.
        var text = ""
        for number in 0..<30_000 { text += number % 1_000 == 999 ? String(repeating: "w", count: 5_000) + "\n" : "\n" }
        let data = Data(text.utf8)
        let reference = document(data, columns: 80, segment: 1 << 30, chunk: 1 << 20)
        for (segment, chunk) in [(1 << 16, 1 << 12), (777, 100), (1 << 20, 99)] {
            let other = document(data, columns: 80, segment: segment, chunk: chunk, parallel: true)
            #expect(
                other.rowCount == reference.rowCount && other.lineCount == reference.lineCount,
                "\(segment)/\(chunk)"
            )
            for row in stride(from: 0, to: reference.rowCount, by: 997) {
                let expected = try reference.rows(from: row, count: 3, cancellation: nil)
                    .map { "\($0.range) \($0.line) \($0.startsLine)" }
                #expect(
                    try other.rows(from: row, count: 3, cancellation: nil)
                        .map { "\($0.range) \($0.line) \($0.startsLine)" } == expected,
                    "row \(row) \(segment)/\(chunk)"
                )
            }
            #expect(
                try other.row(ofLine: 20_000, cancellation: nil) == reference.row(ofLine: 20_000, cancellation: nil)
            )
        }
    }

    /// A file that became shorter while it was indexed is reported as changed, in both builds; what was read is shown.
    @Test
    internal func aFileThatBecameShorterIsReportedNotShownAsComplete() {
        let source = Shrunk(length: 100_000, available: 30_000)
        let document = indexed(
            source,
            TextLayoutOptions(columns: 50, wordWrap: true, tabWidth: 8),
            scanning: TextRowIndex.ScanOptions(segmentSize: 8_192, chunkSize: 1_024, rawScan: true),
            parallel: false
        )
        #expect(document.readError as? ViewerError == .fileChanged)
        // What was there is shown.
        #expect(document.rowCount > 0)
        // The same in the parallel build.
        let other = indexed(
            source,
            TextLayoutOptions(columns: 50, wordWrap: true, tabWidth: 8),
            scanning: TextRowIndex.ScanOptions(segmentSize: 8_192, chunkSize: 1_024, rawScan: true),
            parallel: true
        )
        #expect(other.readError as? ViewerError == .fileChanged)
    }

    /// Reading rows of a file that became shorter reports an error, in text and byte layouts, instead of trapping.
    @Test
    internal func rowsOfAFileThatBecameShorterAreReportedAndDoNotTrap() throws {
        let data = Data(repeating: UInt8(ascii: "z"), count: 5_000)
        let full = DataByteSource(data)
        let document = indexed(
            full,
            TextLayoutOptions(columns: 50, wordWrap: true, tabWidth: 8),
            scanning: .standard,
            parallel: false
        )
        #expect(document.readError == nil)
        // Reading with a source that now has less.
        let shorter = indexed(
            Shrunk(length: 5_000, available: 1_000),
            TextLayoutOptions(columns: 50, wordWrap: true, tabWidth: 8),
            scanning: .standard,
            parallel: false
        )
        _ = try shorter.rows(from: 0, count: 200, cancellation: nil)
        #expect(shorter.readError != nil)
        // The byte layouts too.
        let hex = TextDocument(
            source: Shrunk(length: 5_000, available: 100),
            encoding: .ansi,
            bomLength: 0,
            layout: .hex,
            reusing: nil
        )
        _ = try hex.rows(from: 0, count: 100, cancellation: nil)
        #expect(hex.readError as? ViewerError == .fileChanged)
    }

    /// A segment that could not be read gives no rows; the others are numbered without a gap, in order.
    @Test
    internal func rowsAreNeverReadThroughASegmentThatFailed() throws {
        // 200 lines of 20 bytes, segments of 400 bytes: the third segment (800..<1200) cannot be read.
        var text = ""
        for number in 0..<200 { text += String(format: "line %04d  xxxxxxxx\n", number) }
        let data = Data(text.utf8)
        let source = Gappy(data, unreadable: 800..<1_200)
        let document = indexed(
            source,
            TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8),
            scanning: TextRowIndex.ScanOptions(segmentSize: 400, chunkSize: 100, rawScan: true),
            parallel: false
        )
        #expect(document.readError != nil)
        let rows = try document.rows(from: 0, count: document.rowCount, cancellation: nil)
        #expect(rows.count == document.rowCount)
        // The numbers go up by one and no row has bytes of the segment that failed.
        #expect(rows.map(\.index) == Array(0..<rows.count))
        #expect(rows.allSatisfy { !($0.range.lowerBound >= 800 && $0.range.lowerBound < 1_200) })
        #expect(rows.map(\.range.lowerBound) == rows.map(\.range.lowerBound).sorted())
        #expect(Set(rows.map(\.range.lowerBound)).count == rows.count)
    }
}
