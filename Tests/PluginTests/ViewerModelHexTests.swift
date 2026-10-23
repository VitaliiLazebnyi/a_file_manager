import Foundation
import Testing

@testable import ViewerPlugin

/// The viewer's byte layouts without any window: hex rows, binary rows and selections in them.
@Suite
internal struct ViewerModelHexTests {
    /// A document of the bytes in the encoding and one of the byte layouts, which need no index.
    private func document(_ data: Data, _ encoding: ViewerEncoding, _ layout: ViewerLayout) -> TextDocument {
        TextDocument(source: DataByteSource(data), encoding: encoding, bomLength: 0, layout: layout, reusing: nil)
    }

    /// Hex rows show the offset, sixteen bytes in two groups and the characters, as specified.
    @Test
    internal func hexRowsLookAsInTheSpecification() throws {
        let data = Data("Report 1\r\nLorem ipsum dolor".utf8)
        let document = document(data, .ansi, .hex)
        let rows = try document.rows(from: 0, count: 10, cancellation: nil)
        #expect(
            rows.map(\.text) == [
                "00000000: 52 65 70 6F 72 74 20 31|0D 0A 4C 6F 72 65 6D 20 | Report 1..Lorem ",
                "00000010: 69 70 73 75 6D 20 64 6F|6C 6F 72                | ipsum dolor"
            ]
        )
        #expect(document.rowCount == 2 && rows[1].range == 16..<27)
        let short = try self.document(Data([0x0D, 0x0A]), .ansi, .hex).rows(from: 0, count: 1, cancellation: nil)
        #expect(short[0].text == "00000000: 0D 0A" + String(repeating: " ", count: 43) + "| ..")
        #expect(
            HexFormat(length: 0x1_0000_0000).offsetDigits == 8 && HexFormat(length: 0x1_0000_0001).offsetDigits == 9
        )
        #expect(HexFormat.hexString(Data([0x52, 0x65, 0x00, 0xFF])) == "52 65 00 FF")
    }

    /// A selection of bytes shows in both the hex and the character part of a hex row, and places map back to bytes.
    @Test
    internal func aSelectionShowsInBothPartsOfAHexRow() throws {
        let document = document(Data((0..<40).map { UInt8($0 + 0x30) }), .ansi, .hex)
        let row = try #require(try document.rows(from: 1, count: 1, cancellation: nil).first)
        // Bytes 18…20 of the file are the third to fifth of the second row.
        #expect(document.textRanges(in: row, for: 18..<21) == [16..<24, 62..<65])
        #expect(document.textRanges(in: row, for: 0..<16).isEmpty)
        #expect(
            document.byteOffset(in: row, at: 16) == 18 && document.byteOffset(in: row, at: 17) == 18
                && document.byteOffset(in: row, at: 63) == 19
        )
        #expect(document.byteOffset(in: row, at: 0) == 16 && document.byteOffset(in: row, at: 500) == 32)
        #expect(document.textIndex(in: row, of: 20) == 22)
    }

    /// Binary rows have a fixed length, dots for control characters, and one byte per character in any encoding.
    @Test
    internal func binaryRowsHaveAFixedLengthAndDotsForControlCharacters() throws {
        let data = Data(Array("ab\r\ncd\u{0}ef".utf8) + [0xE4, 0xFF])
        let document = document(data, .ansi, .binary(width: 4))
        #expect(document.rowCount == 3)
        let rows = try document.rows(from: 0, count: 10, cancellation: nil)
        #expect(rows.map(\.text) == ["ab..", "cd.e", "fäÿ"] && rows.map(\.range) == [0..<4, 4..<8, 8..<11])
        #expect(
            try document.row(containing: 9, cancellation: nil) == 2 && document.row(ofLine: 2, cancellation: nil) == 1
        )
        #expect(document.textRanges(in: rows[1], for: 5..<9) == [1..<4])
        // In another character set the same bytes are other characters.
        #expect(
            try self.document(Data([0xC9, 0xCD, 0xBB]), .dos, .binary(width: 75))
                .rows(from: 0, count: 1, cancellation: nil).first?
                .text
                == "╔═╗"
        )
        // A multi-byte encoding falls back to one byte per character.
        #expect(self.document(data, .utf8, .binary(width: 4)).encoding == .ansi)
    }
}
