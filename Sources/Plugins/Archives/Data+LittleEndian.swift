import Foundation

/// Little-endian numbers appended to a block of bytes, as ZIP and GZIP store them.
extension Data {
    /// Appends `value` as two bytes, the low one first.
    internal mutating func appendLE(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }

    /// Appends `value` as four bytes, the lowest first.
    internal mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(value & 0xFFFF))
        appendLE(UInt16(value >> 16))
    }

    /// Appends `value` as eight bytes, the lowest first.
    internal mutating func appendLE(_ value: UInt64) {
        appendLE(UInt32(value & 0xFFFF_FFFF))
        appendLE(UInt32(value >> 32))
    }
}
