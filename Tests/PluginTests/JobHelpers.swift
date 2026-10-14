import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport

/// A registry with the local disk and an in-memory file system, as two plugins would provide.
func makeFileSystems() -> (FileSystemRegistry, MemoryFileSystem) {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()
    fileSystems.register(LocalFileSystem())
    fileSystems.register(memory)
    return (fileSystems, memory)
}

/// Answers a job's questions with fixed choices and records what was asked.
final class Answers: FileJobDelegate {
    var conflict: ConflictChoice = .overwrite
    var folderDelete: FolderDeleteChoice = .delete
    var failure: ErrorChoice = .skip
    var cancelAtBytes: Int64?
    var cancelAtItems: Int?
    var conflicts: [String] = []
    var errors: [String] = []
    var nonEmptyQuestions: [String] = []
    var progress: [JobProgress] = []

    func job(_ job: FileJob, progress: JobProgress) {
        self.progress.append(progress)
        if let cancelAtBytes, progress.bytesDone >= cancelAtBytes { job.cancel() }
        if let cancelAtItems, progress.itemsDone >= cancelAtItems { job.cancel() }
    }

    func job(_ job: FileJob, conflictAt target: FileItem, source: FileItem) -> ConflictChoice {
        conflicts.append(target.name)
        return conflict
    }

    func job(_ job: FileJob, failedAt url: URL, error: Error) -> ErrorChoice {
        errors.append(error.localizedDescription)
        return failure
    }

    func job(_ job: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice {
        nonEmptyQuestions.append(directory.lastPathComponent)
        return folderDelete
    }
}

@discardableResult
func runJob(
    _ kind: JobKind, _ sources: [URL], to target: TargetSpec? = nil, answers: Answers = Answers(),
    fileSystems: FileSystemRegistry = makeFileSystems().0
) -> JobResult {
    let job = FileJob(kind: kind, sources: sources, target: target, fileSystems: fileSystems)
    job.delegate = answers
    return job.run()
}

/// The names in a folder of the local disk, hidden ones too, sorted.
func namesOnDisk(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}
