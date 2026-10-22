import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Review round 2, the row index: lines longer than a segment, files that become shorter or
/// unreadable while they are indexed, and rows that are never cut in front of a mark.
@Suite struct Review2ViewerRows {
    private func document(
        _ data: Data,
        columns: Int,
        segment: Int,
        chunk: Int,
        wrap: Bool = true,
        parallel: Bool = false
    ) -> TextDocument {
        let document = TextDocument(
            source: DataByteSource(data),
            encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: columns, wordWrap: wrap))
        )
        document.buildIndex(parallel: parallel, segmentSize: segment, chunkSize: chunk)
        return document
    }

    // MARK: Segment.thin

    @Test func aSegmentWithMoreCheckpointsThanBytesIsThinnedAndDoesNotTrap() {
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

    @Test func theReproducerOfTheFuzzerIndexes() throws {
        // 66 bytes in one line, one column wide, segments of one byte: two checkpoints for a
        // one-byte segment (rows-thin-overflow.bin).
        let data = Data(repeating: UInt8(ascii: "q"), count: 66)
        for (segment, chunk) in [(1, 16), (2, 16), (7, 16), (64, 20)] {
            let index = document(data, columns: 1, segment: segment, chunk: chunk)
            #expect(index.isIndexComplete && index.readError == nil)
            #expect(index.rowCount == 66 && index.lineCount == 1, "segment \(segment)")
            let rows = try index.rows(from: 0, count: 66)
            #expect(rows.map(\.text) == Array(repeating: "q", count: 66))
        }
    }

    @Test func aGiantLineKeepsFewCheckpointsAndEveryRowCanBeFound() throws {
        // A line of 6 MB in segments of 16 KB: all its rows belong to the first segment.
        let size = 6 << 20
        var bytes = Data(count: size)
        for index in 0..<size { bytes[index] = UInt8(ascii: "a") + UInt8(index % 26) }
        let columns = 20
        let index = document(bytes, columns: columns, segment: 16 << 10, chunk: 1 << 16, parallel: true)
        #expect(
            index.isIndexComplete && index.rowCount == size / columns + (size % columns == 0 ? 0 : 1)
                && index.lineCount == 1
        )
        // About one checkpoint per 4 KB of the line, not one per 64 rows (1,280 bytes).
        let bound = size / TextRowIndex.minimumCheckpointDistance * 2 + 8
        #expect(index.checkpointCount <= bound, "checkpoints \(index.checkpointCount)")
        for row in [0, 1, 63, 64, 65, 4_095, 123_456, index.rowCount - 1] {
            let found = try #require(try index.rows(from: row, count: 1).first)
            let lower = row * columns
            #expect(found.range == Int64(lower)..<Int64(min(size, lower + columns)), "row \(row)")
            #expect(found.text == String(decoding: bytes[lower..<min(size, lower + columns)], as: UTF8.self))
            #expect(try index.row(containing: Int64(lower + 3)) == row)
        }
    }

    @Test func aSegmentNeverHoldsMoreCheckpointsThanTheLimit() {
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

    @Test func aChunkedCheckpointListKeepsACopyUnchangedWhileTheOriginalGrows() {
        var list = TextRowIndex.CheckpointList()
        for number in 0..<9_000 {
            list.append(.init(offset: Int64(number) * 3, linesBefore: number, startsLine: number % 2 == 0))
        }
        let copy = list
        for number in 9_000..<20_000 {
            list.append(.init(offset: Int64(number) * 3, linesBefore: number, startsLine: number % 2 == 0))
        }
        #expect(copy.count == 9_000 && list.count == 20_000)
        for number in [0, 1, 4_095, 4_096, 4_097, 8_191, 8_999] {
            #expect(
                copy[number].offset == Int64(number) * 3 && copy[number].linesBefore == number
                    && copy[number].startsLine == (number % 2 == 0)
            )
        }
        #expect(list[19_999].linesBefore == 19_999 && list[9_000].offset == 27_000)
        let thinned = list.thinned(every: 7)
        #expect(thinned.count == 2_858 && thinned[1].offset == 21 && thinned[2_857].linesBefore == 19_999)
    }

    @Test func thinningWhileScanningGivesTheRowsOfScanningThenThinning() throws {
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
                let expected = try reference.rows(from: row, count: 3).map { "\($0.range) \($0.line) \($0.startsLine)" }
                #expect(
                    try other.rows(from: row, count: 3).map { "\($0.range) \($0.line) \($0.startsLine)" } == expected,
                    "row \(row) \(segment)/\(chunk)"
                )
            }
            #expect(try other.row(ofLine: 20_000) == reference.row(ofLine: 20_000))
        }
    }

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
    }

    @Test func aFileThatBecameShorterIsReportedNotShownAsComplete() {
        let source = Shrunk(length: 100_000, available: 30_000)
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: 50, wordWrap: true))
        )
        document.buildIndex(parallel: false, segmentSize: 8_192, chunkSize: 1_024)
        #expect(document.readError as? ViewerError == .fileChanged)
        // What was there is shown.
        #expect(document.rowCount > 0)
        // The same in the parallel build.
        let other = TextDocument(
            source: source,
            encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: 50, wordWrap: true))
        )
        other.buildIndex(parallel: true, segmentSize: 8_192, chunkSize: 1_024)
        #expect(other.readError as? ViewerError == .fileChanged)
    }

    @Test func rowsOfAFileThatBecameShorterAreReportedAndDoNotTrap() throws {
        let data = Data(repeating: UInt8(ascii: "z"), count: 5_000)
        let full = DataByteSource(data)
        let document = TextDocument(
            source: full,
            encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: 50, wordWrap: true))
        )
        document.buildIndex(parallel: false)
        #expect(document.readError == nil)
        // Reading with a source that now has less.
        let shorter = TextDocument(
            source: Shrunk(length: 5_000, available: 1_000),
            encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: 50, wordWrap: true))
        )
        shorter.buildIndex(parallel: false)
        _ = try shorter.rows(from: 0, count: 200)
        #expect(shorter.readError != nil)
        // The byte layouts too.
        let hex = TextDocument(source: Shrunk(length: 5_000, available: 100), encoding: .ansi, layout: .hex)
        _ = try hex.rows(from: 0, count: 100)
        #expect(hex.readError as? ViewerError == .fileChanged)
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
    }

    @Test func rowsAreNeverReadThroughASegmentThatFailed() throws {
        // 200 lines of 20 bytes, segments of 400 bytes: the third segment (800..<1200) cannot be read.
        var text = ""
        for number in 0..<200 { text += String(format: "line %04d  xxxxxxxx\n", number) }
        let data = Data(text.utf8)
        let source = Gappy(data, unreadable: 800..<1_200)
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true))
        )
        document.buildIndex(parallel: false, segmentSize: 400, chunkSize: 100)
        #expect(document.readError != nil)
        let rows = try document.rows(from: 0, count: document.rowCount)
        #expect(rows.count == document.rowCount)
        // The numbers go up by one and no row has bytes of the segment that failed.
        #expect(rows.map(\.index) == Array(0..<rows.count))
        #expect(rows.allSatisfy { !($0.range.lowerBound >= 800 && $0.range.lowerBound < 1_200) })
        #expect(rows.map(\.range.lowerBound) == rows.map(\.range.lowerBound).sorted())
        #expect(Set(rows.map(\.range.lowerBound)).count == rows.count)
    }

    // MARK: Marks

    @Test func aRowIsNotCutBetweenACharacterAndItsMark() throws {
        // "aaa" and then é as e + U+0301, three columns wide: the mark stays with its letter.
        let text = "aaae\u{0301}bbb\n"
        let index = document(Data(text.utf8), columns: 4, segment: 1 << 20, chunk: 1 << 20)
        let rows = try index.rows(from: 0, count: index.rowCount).map(\.text)
        #expect(rows == ["aaae\u{0301}", "bbb"], "\(rows)")
    }

    @Test func aJoinedSequenceStaysInOneRow() throws {
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let text = "ab" + family + "cd\n"
        let index = document(Data(text.utf8), columns: 4, segment: 1 << 20, chunk: 1 << 20)
        let rows = try index.rows(from: 0, count: index.rowCount).map(\.text)
        // The sequence is in a row whole.
        #expect(rows.contains { $0.contains(family) }, "\(rows)")
    }

    @Test func aRunOfMarksIsCutAfterAWhile() throws {
        // No unit of this line takes a column: still no row is longer than a few times the width.
        let text = String(repeating: "\u{0301}", count: 1_000) + "\n"
        let index = document(Data(text.utf8), columns: 10, segment: 1 << 20, chunk: 1 << 20)
        let rows = try index.rows(from: 0, count: index.rowCount)
        #expect(rows.count > 1 && rows.allSatisfy { $0.text.utf16.count <= 10 * 4 + 16 + 1 })
    }
}
