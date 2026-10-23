import Foundation
import zlib

/// CRC32 with the system's zlib, which uses the processor's CRC instructions.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class CRC32Hasher: StreamHasher, @unchecked Sendable {
    /// The CRC so far, as zlib keeps it.
    internal private(set) var value: UInt = zlib.crc32(0, nil, 0)

    /// The CRC so far, in its 32 bits.
    internal var checksum: UInt32 { UInt32(truncatingIfNeeded: value) }

    /// Adds the next block, in pieces of at most 1 GB (zlib counts in 32 bits).
    internal func update(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard !buffer.isEmpty, var pointer = buffer.bindMemory(to: Bytef.self).baseAddress else {
                return
            }
            var left = buffer.count
            // zlib counts in 32 bits.
            while left > 0 {
                let step = min(left, 1 << 30)
                value = zlib.crc32(value, pointer, uInt(step))
                pointer += step
                left -= step
            }
        }
    }

    /// The four bytes of the CRC, the highest first.
    internal func finish() -> [UInt8] {
        withUnsafeBytes(of: checksum.bigEndian, Array.init)
    }

    deinit {
        // Nothing to release.
    }
}
