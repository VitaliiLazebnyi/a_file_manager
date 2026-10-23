import Foundation
import Testing

@testable import ViewerPlugin

/// Rows and the characters that are made of several code points: a letter and its marks, joined emoji, marks alone.
extension Review2ViewerRowsTests {
    /// The UTF-8 `text` laid out in `columns`, word-wrapped, its rows found in one segment.
    private func laidOut(_ text: String, columns: Int) -> TextDocument {
        indexed(
            DataByteSource(Data(text.utf8)),
            TextLayoutOptions(columns: columns, wordWrap: true, tabWidth: 8),
            scanning: TextRowIndex.ScanOptions(segmentSize: 1 << 20, chunkSize: 1 << 20, rawScan: true),
            parallel: false
        )
    }

    /// A row is not cut between a letter and the combining mark after it.
    @Test
    internal func aRowIsNotCutBetweenACharacterAndItsMark() throws {
        // "aaa" and then é as e + U+0301, three columns wide: the mark stays with its letter.
        let text = "aaae\u{0301}bbb\n"
        let index = laidOut(text, columns: 4)
        let rows = try index.rows(from: 0, count: index.rowCount, cancellation: nil).map(\.text)
        #expect(rows == ["aaae\u{0301}", "bbb"], "\(rows)")
    }

    /// An emoji sequence joined by zero-width joiners stays whole in one row.
    @Test
    internal func aJoinedSequenceStaysInOneRow() throws {
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let text = "ab" + family + "cd\n"
        let index = laidOut(text, columns: 4)
        let rows = try index.rows(from: 0, count: index.rowCount, cancellation: nil).map(\.text)
        // The sequence is in a row whole.
        #expect(rows.contains { $0.contains(family) }, "\(rows)")
    }

    /// A long run of marks that take no column is still cut into rows of bounded length.
    @Test
    internal func aRunOfMarksIsCutAfterAWhile() throws {
        // No unit of this line takes a column: still no row is longer than a few times the width.
        let text = String(repeating: "\u{0301}", count: 1_000) + "\n"
        let index = laidOut(text, columns: 10)
        let rows = try index.rows(from: 0, count: index.rowCount, cancellation: nil)
        #expect(rows.count > 1 && rows.allSatisfy { $0.text.utf16.count <= 10 * 4 + 16 + 1 })
    }
}
