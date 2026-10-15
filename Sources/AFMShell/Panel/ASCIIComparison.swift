/// What comparing typed text with a name byte by byte found out. Typed text and most names are
/// plain ASCII, and those are compared that way, several times faster than Foundation does it;
/// a name with anything else in it is left to Foundation (`unknown`).
internal enum ASCIIComparison {
    /// The name matches.
    case match
    /// The name does not match.
    case mismatch
    /// The bytes cannot tell: Foundation has to compare.
    case unknown

    /// An ASCII capital letter made small; every other byte as it is.
    @inline(__always)
    internal static func lowercase(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }

    /// Whether `bytes` contains `needle` (lowercase ASCII), upper and lower case being the same.
    internal static func contains(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Self {
        guard !bytes.contains(where: { $0 >= 0x80 }) else {
            return .unknown
        }
        guard bytes.count >= needle.count else {
            return .mismatch
        }
        for start in 0...(bytes.count - needle.count) where starts(bytes, at: start, with: needle) {
            return .match
        }
        return .mismatch
    }

    /// Whether `bytes` starts with `needle` (lowercase ASCII), upper and lower case being the same.
    internal static func hasPrefix(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Self {
        guard bytes.count >= needle.count else {
            // Shorter than what was typed: no match, unless it holds something that folds.
            return bytes.contains { $0 >= 0x80 } ? .unknown : .mismatch
        }
        for index in needle.indices {
            let byte = bytes[index]
            if byte >= 0x80 {
                return .unknown
            }
            if lowercase(byte) != needle[index] {
                return .mismatch
            }
        }
        // What follows may join the last letter (an accent written after it).
        if bytes.count > needle.count, bytes[needle.count] >= 0x80 {
            return .unknown
        }
        return .match
    }

    /// Whether the ASCII bytes from `start` on are `needle`, upper and lower case being the same.
    private static func starts(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, with needle: [UInt8]) -> Bool {
        var index = 0
        while index < needle.count, lowercase(bytes[start + index]) == needle[index] {
            index += 1
        }
        return index == needle.count
    }
}
