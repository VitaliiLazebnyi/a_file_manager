import AFMKernel

/// Copying members with a cancellation flag instead of a check.
extension ZipWriter {
    /// `copyMember`, ended early (with `ArchiveError.cancelled`) when the flag is set.
    internal func copyMember(_ record: ZipRecord, cancellation: CancellationFlag?) throws -> UInt64 {
        try copyMember(record) { if cancellation?.isCancelled == true { throw ArchiveError.cancelled } }
    }
}
