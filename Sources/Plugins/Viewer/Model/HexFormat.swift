import Foundation

/// The hex display of the specification (10 › Hex):
/// `00000000: 52 65 70 6F 72 74 20 31|0D 0A 4C 6F 72 65 6D 20 | Report 1..Lorem `.
internal struct HexFormat: Equatable {
    /// The bytes of a hex row.
    internal static let bytesPerRow = 16
    /// Eight digits as in the specification; more for files they cannot address.
    internal let offsetDigits: Int

    /// The format of a file of `length` bytes.
    internal init(length: Int64) {
        offsetDigits = max(8, String(max(0, length - 1), radix: 16).count)
    }

    /// Control characters and bytes without a character show as a dot (spec 10 › Binary, Hex).
    internal static func printable(_ unit: UInt16) -> UInt16 {
        unit < 0x20 || (0x7F...0x9F).contains(unit) || unit == CodeTable.leadByte || unit == CodeTable.replacement
            ? 0x2E : unit
    }

    /// Bytes as hexadecimal text for the clipboard: `52 65 70 6F`.
    internal static func hexString(_ data: Data) -> String {
        let digits = Array("0123456789ABCDEF".utf16)
        var text: [UInt16] = []
        text.reserveCapacity(data.count * 3)
        for byte in data {
            if !text.isEmpty { text.append(0x20) }
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF16.self)
    }

    /// The column of the first hex digit of byte `position` in a row.
    internal func hexColumn(_ position: Int) -> Int { offsetDigits + 2 + position * 3 }
    /// The column of the character of byte `position`.
    internal func characterColumn(_ position: Int) -> Int { offsetDigits + 2 + Self.bytesPerRow * 3 + 2 + position }

    /// The hex row of `bytes` (at most 16), which begin at `offset`; the characters come from
    /// `table`.
    internal func line(offset: Int64, bytes: [UInt8], table: CodeTable) -> String {
        let digits = Array("0123456789ABCDEF".utf16)
        var units: [UInt16] = []
        units.reserveCapacity(characterColumn(Self.bytesPerRow))
        let offsetText = String(offset, radix: 16, uppercase: true)
        units.append(contentsOf: repeatElement(0x30, count: max(0, offsetDigits - offsetText.count)))
        units.append(contentsOf: offsetText.utf16)
        units.append(contentsOf: [0x3A, 0x20])
        for position in 0..<Self.bytesPerRow {
            if position < bytes.count {
                units.append(digits[Int(bytes[position] >> 4)])
                units.append(digits[Int(bytes[position] & 0x0F)])
                units.append(position == 7 && bytes.count > 8 ? 0x7C : 0x20)
            } else {
                units.append(contentsOf: [0x20, 0x20, 0x20])
            }
        }
        units.append(contentsOf: [0x7C, 0x20])
        for byte in bytes { units.append(Self.printable(table.single[Int(byte)])) }
        return String(decoding: units, as: UTF16.self)
    }
}
