import Foundation
import zlib

/// Deflate compression (ZIP method 8, GZIP) through zlib.
internal enum Deflater {
    /// One independent piece of a deflate stream, at level 1 (fast) … 9 (small).
    ///
    /// Pieces made this way, each on its own core, form one valid stream when written one after the
    /// other; the last one is `final`, the others end their block on a byte boundary without ending
    /// the stream. Throws when zlib fails, rather than hand on a piece that is cut short.
    internal static func piece(_ data: Data, level: Int, final: Bool, calls: DeflateCalls) throws -> Data {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer { stream.deallocate() }
        let started = calls.start(stream, Int32(max(1, min(level, 9))))
        guard started == Z_OK else { throw failure(started) }
        defer { deflateEnd(stream) }
        var output = Data()
        let capacity = max(1 << 14, min(data.count / 2 + 1_024, 1 << 20))
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { chunk.deallocate() }
        let mode = final ? Z_FINISH : Z_SYNC_FLUSH
        try data.withUnsafeBytes { bytes in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(bytes.count)
            defer { stream.pointee.next_in = nil }
            while true {
                stream.pointee.next_out = chunk
                stream.pointee.avail_out = uInt(capacity)
                let status = calls.run(stream, mode)
                guard status != Z_STREAM_ERROR else { throw failure(status) }
                output.append(chunk, count: capacity - Int(stream.pointee.avail_out))
                if status == Z_STREAM_END { break }
                // Done when the output buffer was not filled and the input is used up.
                if stream.pointee.avail_out != 0, stream.pointee.avail_in == 0 { break }
            }
        }
        return output
    }

    private static func failure(_ status: Int32) -> ArchiveError {
        .toolFailed("The data could not be compressed (zlib error \(status)).")
    }
}
