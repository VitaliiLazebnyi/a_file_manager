import AFMKernel
import Foundation

/// Compresses a stream of bytes on all cores: the stream is cut into pieces, the pieces are
/// compressed at the same time and written in order.
///
/// Each of the three formats allows that: deflate pieces join into one stream, and BZIP2 and XZ
/// files may consist of several streams. Used by one thread; the pieces are compressed on the
/// others.
internal final class ParallelCompressor {
    /// How the bytes are compressed.
    internal enum Method: Equatable {
        /// BZIP2, at a level from 1 to 9, through the system's bzip2.
        case bzip2(level: Int)
        /// GZIP (deflate), at a level from 1 to 9.
        case gzip(level: Int)
        /// Not at all: the bytes are written as they come.
        case uncompressed
        /// LZMA in the `.xz` container.
        case xzStream
    }

    private let method: Method
    private let output: OutputFile
    private var buffer = Data()
    private var crc: UInt32 = 0
    private var total: UInt64 = 0
    private var wroteAnything = false
    private let pieceSize: Int
    private let windowSize: Int

    private var isDeflate: Bool {
        if case .gzip = method {
            return true
        }
        return false
    }

    /// A compressor that writes to `output`; for GZIP the header is written at once, with `modified` as the
    /// time of the contents.
    internal init(_ method: Method, to output: OutputFile, modified: Date) throws {
        self.method = method
        self.output = output
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch method {
        case .uncompressed:
            (pieceSize, windowSize) = (1 << 20, 1 << 20)

        case .gzip:
            (pieceSize, windowSize) = (1 << 20, (1 << 20) * cores)

        case .bzip2:
            (pieceSize, windowSize) = (4 << 20, (4 << 20) * cores)

        // The LZMA encoder needs a lot of memory per stream, so fewer run at once.
        case .xzStream:
            (pieceSize, windowSize) = (8 << 20, (8 << 20) * min(cores, 4))
        }
        if case .gzip = method {
            var header = Data([0x1F, 0x8B, 8, 0])
            header.appendLE(UInt32(max(0, min(modified.timeIntervalSince1970, Double(UInt32.max)))))
            header.append(contentsOf: [0, 3])
            try output.write(header)
        }
    }

    /// Takes in more bytes; once enough are gathered for every core, they are compressed and written.
    internal func write(_ data: Data) throws {
        if method == .uncompressed {
            try output.write(data)
            return
        }
        buffer.append(data)
        if buffer.count >= windowSize { try drain(final: false) }
    }

    /// Compresses and writes what is left, and for GZIP the checksum and the size after it.
    internal func finish() throws {
        try drain(final: true)
        if case .gzip = method {
            var trailer = Data()
            trailer.appendLE(crc)
            trailer.appendLE(UInt32(truncatingIfNeeded: total))
            try output.write(trailer)
        }
    }

    private func drain(final: Bool) throws {
        // (Without compression `write` passes everything on at once: only the empty last piece is left.)
        var pieces: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= pieceSize || (final && offset < buffer.endIndex) {
            let end = min(offset + pieceSize, buffer.endIndex)
            pieces.append(buffer.subdata(in: offset..<end))
            offset = end
        }
        buffer = Data(buffer[offset...])
        // An empty input still has to become a valid (empty) compressed file.
        if final, pieces.isEmpty, !wroteAnything || isDeflate { pieces = [Data()] }
        guard !pieces.isEmpty else {
            return
        }
        let chosen = method
        let lastIndex = pieces.count - 1
        let results = Parallel.map(
            Array(pieces.enumerated()),
            serialBelow: 2
        ) { index, piece -> Result<(Data, UInt32), any Error> in
            Result {
                switch chosen {
                case .gzip(let level):
                    return (
                        try Deflater.piece(piece, level: level, final: final && index == lastIndex, calls: .zlib),
                        CRC32.of(piece)
                    )

                case .bzip2(let level):
                    return (try Tool.filter(Tool.bzip2, ["-c", "-\(max(1, min(level, 9)))"], input: piece), 0)

                case .xzStream:
                    return (try XZCoder.compress(piece), 0)

                case .uncompressed:
                    return (piece, 0)
                }
            }
        }
        for (piece, result) in zip(pieces, results) {
            let (packed, pieceCRC) = try result.get()
            crc = CRC32.combine(crc, pieceCRC, secondLength: piece.count)
            total += UInt64(piece.count)
            try output.write(packed)
            wroteAnything = true
        }
    }

    deinit {
        // Nothing to release.
    }
}
