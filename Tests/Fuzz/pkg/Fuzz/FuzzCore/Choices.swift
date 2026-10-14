/// Reads choices out of a fuzz input, for targets that build structured values from it.
///
/// Past the end of the input every byte reads as 0.
public struct Choices {
    /// The whole input.
    public let bytes: [UInt8]
    /// Where the next choice is read.
    public private(set) var position = 0

    /// Whether every byte has been read.
    public var atEnd: Bool {
        position >= bytes.count
    }

    /// Choices read from `bytes`, from the first byte on.
    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The next byte.
    public mutating func byte() -> UInt8 {
        guard position < bytes.count else {
            return 0
        }
        position += 1
        return bytes[position - 1]
    }

    /// A number in `0..<bound`, from one byte when `bound` is at most 256 and from two otherwise.
    public mutating func int(_ bound: Int) -> Int {
        if bound <= 1 {
            return 0
        }
        return bound <= 256 ? Int(byte()) % bound : Int(u16()) % bound
    }

    /// The next two bytes, little-endian.
    public mutating func u16() -> UInt16 {
        UInt16(byte()) | UInt16(byte()) << 8
    }

    /// The next four bytes, little-endian.
    public mutating func u32() -> UInt32 {
        UInt32(u16()) | UInt32(u16()) << 16
    }

    /// The next eight bytes, little-endian.
    public mutating func u64() -> UInt64 {
        UInt64(u32()) | UInt64(u32()) << 32
    }

    /// The lowest bit of the next byte.
    public mutating func bool() -> Bool {
        byte() & 1 == 1
    }

    /// The next `count` bytes, fewer at the end of the input.
    public mutating func take(_ count: Int) -> [UInt8] {
        let end = min(bytes.count, position + max(0, count))
        defer { position = end }
        return Array(bytes[position..<end])
    }

    /// Every byte not read yet.
    public mutating func rest() -> [UInt8] {
        take(bytes.count)
    }

    /// The bytes up to the next `separator` (which is read but not returned), or the rest.
    public mutating func until(_ separator: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        while position < bytes.count {
            let next = bytes[position]
            position += 1
            if next == separator {
                break
            }
            out.append(next)
        }
        return out
    }
}
