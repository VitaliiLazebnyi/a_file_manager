import Foundation

/// Little-endian numbers in a block of bytes, as ZIP stores them.
///
/// Reading past the end gives zero instead of a crash: the callers check signatures and lengths.
internal struct ByteReader {
    /// The block that is read.
    internal let data: Data
    /// How many bytes were read so far.
    internal var position = 0

    /// How many bytes are left to read.
    internal var remaining: Int { data.count - position }

    /// A reader at the first byte of `data`.
    internal init(_ data: Data) {
        self.data = data
    }

    /// The next byte, or 0 at the end.
    internal mutating func u8() -> UInt8 {
        guard remaining >= 1 else {
            position = data.count
            return 0
        }
        defer { position += 1 }
        return data[data.startIndex + position]
    }

    /// The next two bytes as a little-endian number.
    internal mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    /// The next four bytes as a little-endian number.
    internal mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
    /// The next eight bytes as a little-endian number.
    internal mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }

    /// The next `count` bytes, or fewer at the end.
    internal mutating func bytes(_ count: Int) -> Data {
        let taken = max(0, min(count, remaining))
        defer { position += taken }
        return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + taken))
    }
}
