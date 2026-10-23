import Compression
import Foundation

/// LZMA in the `.xz` container, through the system's Compression framework.
internal final class XZCoder {
    /// What one call of `process` did.
    internal struct Step {
        /// The bytes that came out.
        internal let output: Data
        /// How much of the input was used.
        internal let consumed: Int
        /// True when the compressed stream ended (after which a new one may start).
        internal let ended: Bool
    }

    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var isOpen = false
    private let encodes: Bool
    private let algorithm: compression_algorithm

    /// An LZMA coder; a test passes an `algorithm` the system does not know, which it refuses
    /// as it would refuse to start one without memory for it.
    internal init(encoding: Bool, algorithm: compression_algorithm) throws {
        encodes = encoding
        self.algorithm = algorithm
        try start()
    }

    /// `data` as one complete `.xz` stream.
    internal static func compress(_ data: Data) throws -> Data {
        try XZCoder(encoding: true, algorithm: COMPRESSION_LZMA).process(data, finish: true, limit: .max).output
    }

    private func start() throws {
        if isOpen { compression_stream_destroy(stream) }
        isOpen =
            compression_stream_init(
                stream,
                encodes ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE,
                algorithm
            )
            == COMPRESSION_STATUS_OK
        guard isOpen else { throw ArchiveError.unsupported("LZMA compression") }
    }

    /// Feeds `input` through the coder, `finish`ing the stream with it when told to; stops once `limit` bytes
    /// came out.
    ///
    /// Returns what came out, how much of the input was used, and whether the compressed stream
    /// ended (after which a new one may start).
    internal func process(_ input: Data, finish: Bool, limit: Int) throws -> Step {
        var output = Data()
        let capacity = 1 << 17
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { chunk.deallocate() }
        var consumed = 0
        var ended = false
        try input.withUnsafeBytes { bytes in
            // The coder wants a valid pointer even for no input.
            stream.pointee.src_ptr = UnsafePointer(chunk)
            if let base = bytes.bindMemory(to: UInt8.self).baseAddress { stream.pointee.src_ptr = base }
            stream.pointee.src_size = bytes.count
            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = capacity
                let status = compression_stream_process(
                    stream,
                    finish ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                )
                output.append(chunk, count: capacity - stream.pointee.dst_size)
                consumed = bytes.count - stream.pointee.src_size
                if status == COMPRESSION_STATUS_END {
                    ended = true
                    break
                }
                guard status == COMPRESSION_STATUS_OK else {
                    throw ArchiveError.damaged("the LZMA data cannot be decoded")
                }
                if output.count >= limit { break }
                if stream.pointee.dst_size != 0, stream.pointee.src_size == 0 { break }
            }
        }
        return Step(output: output, consumed: consumed, ended: ended)
    }

    /// Starts a new stream, for the next of several in a row.
    internal func restart() throws {
        try start()
    }

    deinit {
        if isOpen { compression_stream_destroy(stream) }
        stream.deallocate()
    }
}
