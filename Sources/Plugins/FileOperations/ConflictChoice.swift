/// Answers of the Overwrite dialog (07 › Choices).
///
/// The "all" answers hold for the rest of the job.
public enum ConflictChoice: Equatable, Sendable {
    case overwrite, overwriteAll, skip, skipAll, overwriteAllOlder, cancel
    /// The copied file gets this name instead; if it is taken too, the question comes again.
    case rename(String)
    /// The file at the target is renamed to this name first, then the copy takes its place.
    case renameExisting(String)
    case autoRenameCopied, autoRenameExisting
    /// The source is added to the end of the file at the target (07 › Append).
    case append
    /// The file at the target is the beginning of the source; the rest is added.
    case resume
    case overwriteAllOlderOrSame, copyAllLarger, copyAllSmaller, renameOlderSkipNewer
}
