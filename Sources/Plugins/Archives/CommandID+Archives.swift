import AFMKernel

/// Command names only this plugin uses (spec 17 › Command catalogue).
extension CommandID {
    /// Pack with "Move to archive" ticked.
    internal static let moveToArchive: CommandID = "cm_MoveToArchive"
    /// Tests the marked archives, or the archive the panel is in, by reading every member.
    internal static let testArchive: CommandID = "cm_TestArchive"
    /// Enters the file under the cursor as an archive, whatever its name ends in.
    internal static let openAsArchive: CommandID = "afm_OpenAsArchive"
}
