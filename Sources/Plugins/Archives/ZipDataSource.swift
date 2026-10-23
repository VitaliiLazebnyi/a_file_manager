import Foundation

/// Where the compressed bytes of a member are.
internal enum ZipDataSource {
    /// In an archive file, behind the local header at this offset. The record holds on to the
    /// file it was read from: when the archive is rewritten, whoever still has the record
    /// goes on reading the file its offset belongs to.
    case archive(headerOffset: UInt64, file: RandomAccessFile)
    /// Nowhere: folders and empty files.
    case nowhere
    /// In a temporary file, waiting to be written into the archive.
    case spool(TemporaryFile)
}
