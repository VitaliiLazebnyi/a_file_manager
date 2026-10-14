/// The mutations `Mutate.one` picks from. Each leaves an input it cannot change (too short, nothing
/// to splice with) as it is.
extension Mutate {
    /// Flips one bit.
    internal static func flipBit(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        guard !data.isEmpty else {
            return
        }
        data[rng.below(data.count)] ^= 1 << UInt8(rng.below(8))
    }

    /// Sets one byte to a random value.
    internal static func randomByte(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        guard !data.isEmpty else {
            return
        }
        data[rng.below(data.count)] = UInt8(truncatingIfNeeded: rng.next())
    }

    /// An interesting integer in a 1, 2, 4 or 8-byte field, at random or at a known field offset.
    internal static func interestingInteger(_ data: inout [UInt8], _ rng: inout Rng, _ sources: MutationSources) {
        let width = [1, 2, 2, 4, 4, 4, 8, 8][rng.below(8)]
        guard data.count >= width else {
            return
        }
        let offset = fieldOffset(width: width, in: data, &rng, sources)
        put(rng.pick(interesting), width: width, at: offset, bigEndian: rng.chance(3), in: &data)
    }

    /// A length field plus or minus a little.
    internal static func nudgeLength(_ data: inout [UInt8], _ rng: inout Rng, _ sources: MutationSources) {
        let width = [1, 2, 4, 8][rng.below(4)]
        guard data.count >= width else {
            return
        }
        let offset = fieldOffset(width: width, in: data, &rng, sources)
        let bigEndian = rng.chance(3)
        let value = get(width: width, at: offset, bigEndian: bigEndian, in: data)
        let delta = UInt64(rng.below(4) + 1)
        put(rng.chance(2) ? value &+ delta : value &- delta, width: width, at: offset, bigEndian: bigEndian, in: &data)
    }

    /// Cuts the input off.
    internal static func truncate(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        guard !data.isEmpty else {
            return
        }
        data.removeSubrange(rng.below(data.count)...)
    }

    /// Removes a block.
    internal static func removeBlock(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        guard count > 1 else {
            return
        }
        let start = rng.below(count)
        let length = min(count - start, 1 + rng.below(rng.chance(4) ? count : 16))
        data.removeSubrange(start..<start + length)
    }

    /// Inserts a copy of a block somewhere.
    internal static func duplicateBlock(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        guard count > 0 else {
            return
        }
        let start = rng.below(count)
        let length = min(count - start, 1 + rng.below(rng.chance(4) ? count : 32))
        let block = Array(data[start..<start + length])
        data.insert(contentsOf: block, at: rng.below(count + 1))
    }

    /// Copies a block over another place.
    internal static func copyBlock(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        guard count > 1 else {
            return
        }
        let start = rng.below(count)
        let length = min(count - start, 1 + rng.below(32))
        let target = rng.below(count)
        let block = Array(data[start..<start + length])
        for (index, byte) in block.enumerated() where target + index < data.count {
            data[target + index] = byte
        }
    }

    /// Inserts up to eight random bytes.
    internal static func insertRandomBytes(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        let length = 1 + rng.below(8)
        var bytes: [UInt8] = []
        for _ in 0..<length {
            bytes.append(UInt8(truncatingIfNeeded: rng.next()))
        }
        data.insert(contentsOf: bytes, at: rng.below(count + 1))
    }

    /// Inserts a run of one byte.
    internal static func insertRun(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        let length = 1 + rng.below(rng.chance(8) ? 4_096 : 64)
        let byte: UInt8 =
            rng.chance(2)
            ? rng.pick([0, 0xFF, 0x20, 0x41, 0x2F, 0x0A, 0x30, 0x80, 0x2E, 0x39])
            : UInt8(truncatingIfNeeded: rng.next())
        data.insert(contentsOf: [UInt8](repeating: byte, count: length), at: rng.below(count + 1))
    }

    /// Splices with another input: its tail replaces ours, or a piece of it is inserted.
    internal static func splice(_ data: inout [UInt8], _ rng: inout Rng, _ sources: MutationSources) {
        let other = sources.other
        guard !other.isEmpty else {
            return
        }
        let cut = rng.below(data.count + 1)
        let start = rng.below(other.count)
        if rng.chance(2) {
            data = Array(data[..<cut]) + other[start...]
        } else {
            let length = min(other.count - start, 1 + rng.below(64))
            data.insert(contentsOf: other[start..<start + length], at: cut)
        }
    }

    /// A dictionary token, inserted or written over.
    internal static func token(_ data: inout [UInt8], _ rng: inout Rng, _ sources: MutationSources) {
        guard !sources.dict.isEmpty else {
            return
        }
        let count = data.count
        let token = rng.pick(sources.dict)
        if rng.chance(2) || count < token.count {
            data.insert(contentsOf: token, at: rng.below(count + 1))
        } else {
            let offset = rng.below(count - token.count + 1)
            for (index, byte) in token.enumerated() {
                data[offset + index] = byte
            }
        }
    }

    /// Adds or subtracts a little from one byte.
    internal static func byteArithmetic(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        guard !data.isEmpty else {
            return
        }
        let index = rng.below(data.count)
        let increase = rng.chance(2)
        let delta = UInt8(1 + rng.below(16))
        data[index] = increase ? data[index] &+ delta : data[index] &- delta
    }

    /// Replaces an ASCII number with an interesting one.
    internal static func asciiNumber(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        guard count > 0 else {
            return
        }
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        var start = rng.below(count)
        var tries = 0
        while tries < 64, !digits.contains(data[start]) {
            start = (start + 1) % count
            tries += 1
        }
        guard digits.contains(data[start]) else {
            return
        }
        var end = start
        while end < data.count, digits.contains(data[end]) {
            end += 1
        }
        let texts = [
            "0", "1", "-1", "255", "256", "65535", "65536", "2147483647", "2147483648", "4294967295", "4294967296",
            "9223372036854775807", "9223372036854775808", "18446744073709551615", "18446744073709551616",
            "99999999999999999999999999", "00000000000", "7777777777777777777777", "-9223372036854775808"
        ]
        data.replaceSubrange(start..<end, with: Array(rng.pick(texts).utf8))
    }

    /// Swaps two blocks of the same length.
    internal static func swapBlocks(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        guard count > 4 else {
            return
        }
        let length = 1 + rng.below(min(16, count / 2))
        let first = rng.below(count - length + 1)
        let second = rng.below(count - length + 1)
        for index in 0..<length {
            data.swapAt(first + index, second + index)
        }
    }

    /// Writes a run of one byte over the input.
    internal static func overwriteWithRun(_ data: inout [UInt8], _ rng: inout Rng, _: MutationSources) {
        let count = data.count
        guard count > 0 else {
            return
        }
        let start = rng.below(count)
        let length = min(count - start, 1 + rng.below(16))
        let byte = UInt8(truncatingIfNeeded: rng.chance(2) ? 0 : rng.next())
        for index in start..<start + length {
            data[index] = byte
        }
    }

    /// Where an integer field of `width` bytes goes: at a known field offset half of the time.
    private static func fieldOffset(
        width: Int,
        in data: [UInt8],
        _ rng: inout Rng,
        _ sources: MutationSources
    ) -> Int {
        if !sources.fields.isEmpty, rng.chance(2) {
            return rng.pick(sources.fields)
        }
        return rng.below(data.count - width + 1)
    }
}
