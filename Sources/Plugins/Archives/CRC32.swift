import Foundation
import zlib

/// The checksum of ZIP and GZIP, from the system's zlib (which uses the processor's own
/// instructions for it).
internal enum CRC32 {
    /// The checksum `crc` of the bytes before, carried on over `data`.
    internal static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes -> UInt32 in
            var sum = uLong(crc)
            var offset = 0
            // zlib counts in 32 bits.
            while offset < bytes.count {
                let step = min(bytes.count - offset, 1 << 30)
                let from = bytes.baseAddress?.assumingMemoryBound(to: Bytef.self).advanced(by: offset)
                sum = crc32(sum, from, uInt(step))
                offset += step
            }
            return UInt32(truncatingIfNeeded: sum)
        }
    }

    /// The checksum of `data` alone.
    internal static func of(_ data: Data) -> UInt32 { update(0, data) }

    /// The checksum of two blocks in a row from the checksums of each: lets blocks be summed
    /// on several cores.
    internal static func combine(_ first: UInt32, _ second: UInt32, secondLength: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32_combine(uLong(first), uLong(second), secondLength))
    }
}
