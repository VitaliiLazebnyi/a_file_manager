import Foundation

/// What a compressed file says about its unpacked size without being unpacked.
internal enum CompressedSize {
    /// The size of an `.xz` file's contents, from the indexes at the ends of its streams
    /// (several streams in a row are one file).
    ///
    /// Nil when they cannot be read; every number in them is checked against the file.
    internal static func ofXZ(_ file: RandomAccessFile) -> UInt64? {
        var end = file.size
        var total: UInt64 = 0
        var (streams, steps) = (0, 0)
        while end > 0 {
            steps += 1
            guard end >= 32, end.isMultiple(of: 4), steps < 1 << 20,
                let footer = try? file.read(at: end - 12, count: 12), footer.count == 12
            else { return nil }
            // Zero bytes, four at a time, may stand between streams and after the last.
            if footer.suffix(4).allSatisfy({ $0 == 0 }) {
                end -= 4
                continue
            }
            guard let found = stream(endingAt: end, footer: footer, in: file, adding: total) else {
                return nil
            }
            total = found.total
            end -= found.size
            streams += 1
        }
        return streams > 0 ? total : nil
    }

    /// What the last four bytes of a `.gz` file say: the size of the contents, counted in 32
    /// bits.
    ///
    /// That is the size itself for one stream of less than 4 GB, which is what nearly every such
    /// file is, but nothing in the file proves it. A number too small for the compressed data to
    /// have come from is raised by the 4 GB steps it must have lost.
    internal static func claimedByGzip(_ file: RandomAccessFile) -> UInt64? {
        guard file.size >= 18, let tail = try? file.read(at: file.size - 4, count: 4), tail.count == 4 else {
            return nil
        }
        var reader = ByteReader(tail)
        var size = UInt64(reader.u32())
        // Deflate never makes data noticeably larger: the contents are about as large as the
        // file at the least.
        let least = file.size - file.size / 64
        while size < least { size += 1 << 32 }
        return size
    }

    /// The `.xz` stream that ends at `end` (its 12-byte `footer` read already): how many bytes of the file
    /// it takes, and `total` with its unpacked size added.
    ///
    /// Nil when its index cannot be read, does not fit the file, or the sum overflows.
    private static func stream(
        endingAt end: UInt64,
        footer: Data,
        in file: RandomAccessFile,
        adding total: UInt64
    ) -> (size: UInt64, total: UInt64)? {
        guard footer[10] == 0x59, footer[11] == 0x5A else {
            return nil
        }
        var reader = ByteReader(footer)
        _ = reader.u32()
        let indexSize = (UInt64(reader.u32()) + 1) * 4
        guard indexSize <= 64 << 20, indexSize <= end - 24,
            let index = try? file.read(at: end - 12 - indexSize, count: Int(indexSize)),
            index.count == Int(indexSize), index[0] == 0,
            let listed = blocks(in: index, room: end, adding: total)
        else { return nil }
        let size = 12 + listed.packed + indexSize + 12
        guard size <= end, let head = try? file.read(at: end - size, count: 6),
            [UInt8](head) == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
        else {
            return nil
        }
        return (size, listed.total)
    }

    /// The blocks a stream's `index` lists: the bytes they take in the file (each padded to four bytes), and
    /// `total` with the bytes they unpack to added.
    ///
    /// Nil when the index is cut short, the blocks take more than the `room` the stream can have, or the sum
    /// overflows.
    private static func blocks(in index: Data, room: UInt64, adding total: UInt64) -> (packed: UInt64, total: UInt64)? {
        var position = 1
        // A number of the index: seven bits per byte, the lowest first, the high bit set in all but the last.
        func number() -> UInt64? {
            var (value, shift) = (UInt64(0), UInt64(0))
            while position < index.count, shift < 63 {
                let byte = index[position]
                position += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return value
                }
                shift += 7
            }
            return nil
        }
        guard let count = number(), count <= UInt64(index.count) / 2 else {
            return nil
        }
        var (packed, sum) = (UInt64(0), total)
        for _ in 0..<count {
            guard let unpadded = number(), let unpacked = number(), unpadded <= room else {
                return nil
            }
            let (next, overflow) = sum.addingReportingOverflow(unpacked)
            guard !overflow else {
                return nil
            }
            sum = next
            packed += (unpadded + 3) & ~3
            guard packed <= room else {
                return nil
            }
        }
        return (packed, sum)
    }
}
