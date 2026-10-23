/// A line of the result list as it is shown: the grey caption of a subdirectory, or a row.
internal enum SyncListEntry: Equatable {
    /// The caption of a subdirectory: its path relative to the start directories.
    case header(String)
    /// The index into `SyncSession.rows`.
    case row(Int)
}
