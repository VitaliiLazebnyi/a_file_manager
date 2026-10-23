/// What Verify found for one file.
internal enum VerifyResult: Equatable {
    /// The file has the checksum it should.
    case correct
    /// The file is not there.
    case notFound
    /// The file could not be read to the end.
    case readError
    /// Something in the checksum file itself that cannot be read: a line, or the whole file.
    case unreadable
    /// The file has another checksum.
    case wrongChecksum
}
