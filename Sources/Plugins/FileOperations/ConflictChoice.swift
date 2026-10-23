/// Answers of the Overwrite dialog (07 › Choices).
///
/// The "all" answers hold for the rest of the job.
public enum ConflictChoice: Equatable, Sendable {
    /// The source is added to the end of the file at the target (07 › Append).
    case append
    /// The copied file gets a free name (`name (2).txt`); the target stays, for the rest of the job.
    case autoRenameCopied
    /// The target gets a free name and the copy takes its place, for the rest of the job.
    case autoRenameExisting
    /// The job ends here.
    case cancel
    /// For the rest of the job a larger file overwrites a smaller one; the others are skipped.
    case copyAllLarger
    /// For the rest of the job a smaller file overwrites a larger one; the others are skipped.
    case copyAllSmaller
    /// This file overwrites the target.
    case overwrite
    /// Every file whose name is taken overwrites its target, for the rest of the job.
    case overwriteAll
    /// For the rest of the job an older target is overwritten; a newer one is kept.
    case overwriteAllOlder
    /// For the rest of the job a target that is older or of the same age is overwritten; a newer one is kept.
    case overwriteAllOlderOrSame
    /// The copied file gets this name instead; if it is taken too, the question comes again.
    case rename(String)
    /// The file at the target is renamed to this name first, then the copy takes its place.
    case renameExisting(String)
    /// For the rest of the job an older target is renamed to make room; a newer one is kept and the file skipped.
    case renameOlderSkipNewer
    /// The file at the target is the beginning of the source; the rest is added.
    case resume
    /// This file is not copied.
    case skip
    /// No file whose name is taken is copied, for the rest of the job.
    case skipAll
}
