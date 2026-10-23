public import AFMKernel
public import Foundation

/// The questions and the progress of a job.
///
/// Questions are asked one at a time and may block until the user answers; progress arrives from
/// one thread at a time, but possibly from another thread than the questions and while a question
/// is open. Without a parallel copy everything comes from the thread that runs the job.
public protocol FileJobDelegate: AnyObject {
    func job(_ job: FileJob, progress: JobProgress)
    func job(_ job: FileJob, conflictAt target: FileItem, source: FileItem) -> ConflictChoice
    func job(_ job: FileJob, failedAt url: URL, error: any Error) -> ErrorChoice
    func job(_ job: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice
    func job(_ job: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice
    func job(_ job: FileJob, mergeInto existing: FileItem, source: FileItem) -> MergeChoice
    /// A folder among what is deleted or moved is another volume (a mounted disk, disk image
    /// or share): whether to go on into it, and so delete or empty that volume too.
    func job(_ job: FileJob, crossVolumeAt folder: FileItem, purpose: ProtectionQuestion.Purpose) -> ProtectionChoice
}

/// Whoever does not care about the protection and merge questions goes ahead.
extension FileJobDelegate {
    public func job(_: FileJob, confirm _: ProtectionQuestion) -> ProtectionChoice { .proceed }
    public func job(_: FileJob, mergeInto _: FileItem, source _: FileItem) -> MergeChoice { .merge }
    /// Another volume is never entered without somebody saying so.
    public func job(_: FileJob, crossVolumeAt _: FileItem, purpose _: ProtectionQuestion.Purpose)
        -> ProtectionChoice
    { .skip }
}
