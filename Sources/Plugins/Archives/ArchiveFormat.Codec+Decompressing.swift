import Foundation

/// The stream that decompresses a file of the codec.
extension ArchiveFormat.Codec {
    /// Decompresses the local `file`: in this process for GZIP and XZ, through bzip2 for BZIP2.
    ///
    /// With a `control`, the stream ends with an error once the request is set. Throws when a decoder cannot be
    /// started, or when the file at the path is no longer the one that was opened (bzip2 opens it by its path).
    internal func decompressing(_ file: RandomAccessFile, control: StreamInterrupt?) throws -> any ByteStream {
        switch self {
        case .gzip:
            return InflateStream(FileRangeStream(file, offset: 0, length: nil), wrapping: .gzip, control: control)

        case .xzStream:
            return try XZStream(FileRangeStream(file, offset: 0, length: nil), control: control)

        case .bzip2:
            // The child opens the file by its path: it must still be the file that was listed.
            guard file.isStillAtItsPath else {
                throw ArchiveError.changedOutside(URL(fileURLWithPath: file.path).lastPathComponent)
            }
            return try ProcessStream(Tool.bzip2, ["-dc", "--", file.path], control: control)
        }
    }
}
