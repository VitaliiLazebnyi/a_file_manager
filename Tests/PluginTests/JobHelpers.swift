import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport

/// A registry with the local disk and an in-memory file system, as two plugins would provide.
internal func makeFileSystems() -> (FileSystemRegistry, MemoryFileSystem) {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()
    fileSystems.register(LocalFileSystem())
    fileSystems.register(memory)
    return (fileSystems, memory)
}

/// Answers a job's questions with fixed choices and records what was asked.
internal final class Answers: FileJobDelegate {
    internal var conflict: ConflictChoice = .overwrite
    internal var folderDelete: FolderDeleteChoice = .delete
    internal var failure: ErrorChoice = .skip
    internal var cancelAtBytes: Int64?
    internal var cancelAtItems: Int?
    internal var conflicts: [String] = []
    internal var errors: [String] = []
    internal var nonEmptyQuestions: [String] = []
    internal var progress: [JobProgress] = []

    internal func job(_ job: FileJob, progress: JobProgress) {
        self.progress.append(progress)
        if let cancelAtBytes, progress.bytesDone >= cancelAtBytes { job.cancel() }
        if let cancelAtItems, progress.itemsDone >= cancelAtItems { job.cancel() }
    }

    internal func job(_: FileJob, conflictAt target: FileItem, source _: FileItem) -> ConflictChoice {
        conflicts.append(target.name)
        return conflict
    }

    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        errors.append(error.localizedDescription)
        return failure
    }

    internal func job(_: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice {
        nonEmptyQuestions.append(directory.lastPathComponent)
        return folderDelete
    }
}

@discardableResult
internal func runJob(
    _ kind: JobKind,
    _ sources: [URL],
    to target: TargetSpec? = nil,
    answers: Answers = Answers(),
    fileSystems: FileSystemRegistry = makeFileSystems().0
) -> JobResult {
    let job = FileJob(kind: kind, sources: sources, target: target, fileSystems: fileSystems)
    job.delegate = answers
    return job.run()
}

/// The names in a folder of the local disk, hidden ones too, sorted.
internal func namesOnDisk(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}
