import Foundation
import zlib

/// What a reader delivered so far, compared piece by piece with the reference, so the harness keeps no copy.
internal struct Comparison {
    /// Where the reading began in the member.
    internal let offset: Int
    /// The bytes delivered.
    internal private(set) var got = 0
    /// The CRC-32 of the bytes delivered.
    internal private(set) var crc: uLong = 0
    /// Whether every byte so far matches the reference.
    internal private(set) var matches = true

    /// A comparison of a reading that began at `offset`.
    internal init(offset: Int) {
        self.offset = offset
    }

    /// Compares the next `block` with `reference`; false when the reading must stop (more bytes than the member has).
    internal mutating func take(_ block: Data, reference: Data) -> Bool {
        let position = offset + got
        if position + block.count > reference.count {
            matches = false
            got += block.count
            return false
        }
        var same = true
        var sum = crc
        block.withUnsafeBytes { piece in
            reference.withUnsafeBytes { whole in
                guard let start = whole.baseAddress else {
                    same = false
                    return
                }
                if memcmp(piece.baseAddress, start + position, block.count) != 0 {
                    same = false
                }
            }
            sum = crc32(sum, piece.bindMemory(to: UInt8.self).baseAddress, uInt(block.count))
        }
        crc = sum
        if !same {
            matches = false
        }
        got += block.count
        return true
    }
}
