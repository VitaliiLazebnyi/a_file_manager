public import AFMKernel
public import Foundation

/// The questions and the progress of a job.
///
/// Questions are asked one at a time and may block until the user answers; progress arrives from
/// one thread at a time, but possibly from another thread than the questions and while a question
/// is open. Without a parallel copy everything comes from the thread that runs the job.
public protocol FileJobDelegate: AnyObject {
    /// Where the job stands; may hold the job back while it is paused.
    func job(_ job: FileJob, progress: JobProgress)
    /// What to do with `source`, whose name is taken at `target` (the Overwrite dialog).
    func job(_ job: FileJob, conflictAt target: FileItem, source: FileItem) -> ConflictChoice
    /// What to do after a step at `url` failed with `error`.
    func job(_ job: FileJob, failedAt url: URL, error: any Error) -> ErrorChoice
    /// Whether a folder that is not empty is deleted with everything in it.
    func job(_ job: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice
    /// Whether a protected item (read-only, hidden, locked, or one the Trash cannot take) is changed anyway.
    func job(_ job: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice
    /// Whether `source` is copied into `existing`, a folder of the same name at the target.
    func job(_ job: FileJob, mergeInto existing: FileItem, source: FileItem) -> MergeChoice
    /// A folder among what is deleted or moved is another volume (a mounted disk, disk image
    /// or share): whether to go on into it, and so delete or empty that volume too.
    func job(_ job: FileJob, crossVolumeAt folder: FileItem, purpose: ProtectionQuestion.Purpose) -> ProtectionChoice
}

/// Whoever does not care about the protection and merge questions goes ahead.
extension FileJobDelegate {
    /// Goes ahead with every protected item.
    public func job(_: FileJob, confirm _: ProtectionQuestion) -> ProtectionChoice { .proceed }
    /// Merges every folder into the one of the same name.
    public func job(_: FileJob, mergeInto _: FileItem, source _: FileItem) -> MergeChoice { .merge }
    /// Another volume is never entered without somebody saying so.
    public func job(_: FileJob, crossVolumeAt _: FileItem, purpose _: ProtectionQuestion.Purpose)
        -> ProtectionChoice
    { .skip }
}
