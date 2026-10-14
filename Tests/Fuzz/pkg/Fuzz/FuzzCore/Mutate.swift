/// The generic mutations: bytes, integer fields, blocks, splices and dictionary tokens.
public enum Mutate {
    /// Integers that tend to find edge cases in length and offset fields.
    public static let interesting: [UInt64] = [
        0, 1, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFF_FFFF, 0x8000_0000,
        0xFFFF_FFFF, 0x1_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF,
        0xFFFF_FFFE, 0xFFFE, 2, 16, 32, 64, 512, 1_024, 4_096, 65_534, 0xFFFF_FFFF_FFFF_FFFE
    ]

    /// One mutation each; a mutation listed twice is picked twice as often.
    private static let strategies: [@Sendable (inout [UInt8], inout Rng, MutationSources) -> Void] = [
        flipBit, randomByte, interestingInteger, interestingInteger, nudgeLength, truncate, removeBlock,
        duplicateBlock, copyBlock, insertRandomBytes, insertRun, splice, splice, token, token, byteArithmetic,
        asciiNumber, swapBlocks, overwriteWithRun
    ]

    /// Writes the low `width` bytes of `value` at `offset`; nothing when the field does not fit.
    public static func put(_ value: UInt64, width: Int, at offset: Int, bigEndian: Bool, in data: inout [UInt8]) {
        guard offset >= 0, offset + width <= data.count else {
            return
        }
        for index in 0..<width {
            let shift = UInt64(bigEndian ? (width - 1 - index) * 8 : index * 8)
            data[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    /// The `width`-byte integer at `offset`; 0 when the field does not fit.
    public static func get(width: Int, at offset: Int, bigEndian: Bool, in data: [UInt8]) -> UInt64 {
        guard offset >= 0, offset + width <= data.count else {
            return 0
        }
        var value: UInt64 = 0
        for index in 0..<width {
            let byte = UInt64(data[offset + index])
            value |= byte << UInt64(bigEndian ? (width - 1 - index) * 8 : index * 8)
        }
        return value
    }

    /// Applies one mutation, picked at random, to `data`. `other` is an input to splice with,
    /// `dict` the target's tokens and `fields` the offsets of its size and offset fields.
    public static func one(_ data: inout [UInt8], rng: inout Rng, other: [UInt8], dict: [[UInt8]], fields: [Int]) {
        let sources = MutationSources(other: other, dict: dict, fields: fields)
        let strategy = strategies[rng.below(strategies.count)]
        strategy(&data, &rng, sources)
    }
}
