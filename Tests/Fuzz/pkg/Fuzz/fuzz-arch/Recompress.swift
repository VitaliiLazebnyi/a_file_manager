import Foundation
import FuzzCore

@testable import ArchivesPlugin

/// Mutates what a compressed archive holds and compresses it again, so that changes reach
/// the TAR reader behind the decompressor.
internal func recompressing(_ codec: ArchiveFormat.Codec) -> @Sendable (inout [UInt8], inout Rng) -> Void {
    { bytes, rng in
        var inner = decompressed(bytes, codec)
        guard !inner.isEmpty else {
            return
        }
        for _ in 0..<(1 + rng.below(3)) {
            if rng.chance(2) {
                tarCustom(&inner, &rng)
            } else {
                Mutate.one(&inner, rng: &rng, other: [], dict: kHostileNames, fields: tarFields(inner))
            }
        }
        if inner.count > 60_000 {
            inner.removeSubrange(60_000...)
        }
        compress(inner, codec, into: &bytes)
    }
}

/// What the compressed `bytes` hold; empty when they cannot be read.
private func decompressed(_ bytes: [UInt8], _ codec: ArchiveFormat.Codec) -> [UInt8] {
    let source = DataStream(Data(bytes))
    let stream: (any ByteStream)?
    switch codec {
    case .gzip:
        stream = InflateStream(source, wrapping: .gzip)

    case .xz:
        stream = try? XZStream(source)

    case .bzip2:
        stream = nil
    }
    guard let stream else {
        return []
    }
    return readAll(stream, limit: 4 << 20)
}

/// Everything `stream` gives: empty when that is more than `limit` bytes; what came before an
/// error otherwise.
private func readAll(_ stream: any ByteStream, limit: Int) -> [UInt8] {
    var out = Data()
    defer { stream.close() }
    do {
        while let block = try stream.read(upToCount: 1 << 16) {
            out.append(block)
            if out.count > limit {
                return []
            }
        }
    } catch {
        return [UInt8](out)
    }
    return [UInt8](out)
}

/// Replaces `bytes` with `inner` compressed by `codec`; leaves them as they are when that fails.
private func compress(_ inner: [UInt8], _ codec: ArchiveFormat.Codec, into bytes: inout [UInt8]) {
    switch codec {
    case .gzip:
        bytes = gzipped(inner)

    case .xz:
        if let out = try? XZCoder.compress(Data(inner)) {
            bytes = [UInt8](out)
        }

    case .bzip2:
        // Not reached: bzip2 is not decompressed.
        break
    }
}

/// `inner` as a gzip file: a fixed header, the deflated data, the CRC and the length.
private func gzipped(_ inner: [UInt8]) -> [UInt8] {
    let deflater = Deflater(level: 6)
    let body = deflater.compress(Data(inner), flush: .finish)
    var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + [UInt8](body)
    let crc = CRC32.of(Data(inner))
    for byte in 0..<4 {
        out.append(UInt8(truncatingIfNeeded: crc >> UInt32(byte * 8)))
    }
    let size = UInt32(truncatingIfNeeded: inner.count)
    for byte in 0..<4 {
        out.append(UInt8(truncatingIfNeeded: size >> UInt32(byte * 8)))
    }
    return out
}
