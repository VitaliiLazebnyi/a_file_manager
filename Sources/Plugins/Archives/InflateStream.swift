import Foundation
import zlib

/// Decompresses deflate data from another stream: raw (ZIP members) or wrapped (GZIP files,
/// also several members in a row, as parallel compressors write them).
internal final class InflateStream: ByteStream {
    /// What surrounds the deflate data.
    internal enum Wrapping {
        /// A GZIP file: a header before each member and a checksum after it.
        case gzip
        /// Nothing: the data of a ZIP member.
        case raw
    }

    private static let inputSize = 1 << 16

    private let source: any ByteStream
    private let wrapping: Wrapping
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: InflateStream.inputSize)
    private var isFinished = false
    private var sourceEnded = false
    private let control: StreamInterrupt?

    /// Decompresses `source`; with a `control`, a read ends with an error once the request is set.
    internal init(_ source: any ByteStream, wrapping: Wrapping, control: StreamInterrupt?) {
        self.source = source
        self.wrapping = wrapping
        self.control = control
        stream.initialize(to: z_stream())
        inflateInit2_(stream, wrapping == .raw ? -15 : 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    private func refill() throws {
        guard stream.pointee.avail_in == 0, !sourceEnded else {
            return
        }
        guard let block = try source.read(upToCount: Self.inputSize) else {
            sourceEnded = true
            return
        }
        block.copyBytes(to: input, count: block.count)
        stream.pointee.next_in = input
        stream.pointee.avail_in = uInt(block.count)
    }

    /// The next decompressed bytes, up to `count`; nil at the end, and throws when the data is damaged or cut short.
    internal func read(upToCount count: Int) throws -> Data? {
        guard !isFinished, count > 0 else {
            return nil
        }
        let capacity = min(count, 1 << 20)
        // Decompressed straight into the block that is handed on, which is not cleared first.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        var produced = 0
        do {
            try fill(buffer.assumingMemoryBound(to: Bytef.self), capacity: capacity, produced: &produced)
        } catch {
            buffer.deallocate()
            throw error
        }
        guard produced >= capacity / 2 else {
            // A block much smaller than its room is copied out, so the room is free at once.
            defer { buffer.deallocate() }
            return produced > 0 ? Data(bytes: buffer, count: produced) : nil
        }
        return Data(bytesNoCopy: buffer, count: produced, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }

    private func fill(_ buffer: UnsafeMutablePointer<Bytef>, capacity: Int, produced: inout Int) throws {
        while produced == 0, !isFinished {
            try control?.check()
            try refill()
            stream.pointee.next_out = buffer
            stream.pointee.avail_out = uInt(capacity)
            let status = inflate(stream, Z_NO_FLUSH)
            produced = capacity - Int(stream.pointee.avail_out)
            switch status {
            case Z_OK:
                break

            case Z_STREAM_END:
                // A GZIP file may hold several members one after the other.
                try refill()
                if wrapping == .gzip, stream.pointee.avail_in > 0, stream.pointee.next_in.pointee == 0x1F {
                    inflateReset(stream)
                } else {
                    isFinished = true
                }

            case Z_BUF_ERROR:
                // There is room for output, so only input that has run out stops the decoder:
                // the source has ended (a source never hands over an empty block).
                throw ArchiveError.damaged("the compressed data ends too early")

            default:
                throw ArchiveError.damaged("the compressed data cannot be decoded")
            }
        }
    }

    /// Closes the source.
    internal func close() {
        source.close()
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
        input.deallocate()
    }
}
