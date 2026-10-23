import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

@testable import FileOperationsPlugin

/// What the job tests of the second pass of review round 2 share: a sandbox on the local disk, a memory file
/// system, a probe, and a registry that knows all three.
internal struct P2JobBench {
    /// The temporary folder on the local disk.
    internal let box: Sandbox
    /// Knows the local disk, `memory` and `probe`.
    internal let fileSystems = FileSystemRegistry()
    /// A memory file system with the scheme `mem`.
    internal let memory = MemoryFileSystem()
    /// A memory file system that notes how it is called.
    internal let probe = P2ProbeFileSystem()

    /// A fresh sandbox and the three file systems, registered.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        fileSystems.register(probe)
    }

    /// A job of `kind` over `sources` into `directory` (none for a deletion), answered by `replies` and ended by
    /// `cancellation`.
    internal func job(
        _ kind: JobKind,
        _ sources: [URL],
        to directory: URL?,
        replies: P2Replies,
        cancellation: CancellationFlag
    ) -> FileJob {
        let job = FileJob(
            kind: kind,
            sources: sources,
            target: directory.map { TargetSpec(directory: $0) },
            fileSystems: fileSystems,
            cancellation: cancellation
        )
        job.delegate = replies
        return job
    }
}
