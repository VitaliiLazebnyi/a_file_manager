import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The commit of a target with deferred writes before a move deletes its sources.
@Suite
internal struct FileOpsAdoptCommit {
    /// A value several threads change.
    ///
    /// Unchecked: the state is guarded by `lock`.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        var value: Value { lock.withLock { stored } }

        init(_ value: Value) { stored = value }

        func modify(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }

        deinit {
            // Nothing to release.
        }
    }

    /// A target file system with the capabilities given and an empty `/out`, and a probe on it.
    private func destination(_ capabilities: FileSystemCapabilities) -> (MemoryFileSystem, ProbeFileSystem) {
        let base = MemoryFileSystem(scheme: "dst")
        base.capabilities = capabilities
        base.addDirectory("/out")
        return (base, ProbeFileSystem(base))
    }

    /// A move deletes its sources only after the one commit of the target folder.
    @Test
    internal func sourcesAreDeletedOnlyAfterTheOneCommitOfTheTargetFolder() throws {
        let box = try Sandbox()
        let files = try (1...3).map { try box.file("A/f\($0).txt", "content \($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        var existedAtCommit: [Bool] = []
        probe.onCommit = { existedAtCommit = files.map { FileManager.default.fileExists(atPath: $0.path) } }
        let result = Answers()
            .run(
                .move,
                files,
                to: TargetSpec(directory: base.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: probe)
            )
        #expect(base.commits == ["/out"])
        #expect(existedAtCommit == [true, true, true])
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(Set(result.completed) == Set(files) && !result.cancelled)
        #expect(base.contents("/out/f2.txt") == "content 2")
    }

    /// A moved folder is removed only after the commit too.
    @Test
    internal func aMovedFolderIsRemovedAfterTheCommitToo() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/a.txt", "a")
        try box.file("A/tree/sub/b.txt", "b")
        let (base, probe) = destination([.write, .deferredWrites])
        var treeAtCommit = false
        probe.onCommit = { treeAtCommit = FileManager.default.fileExists(atPath: box.url("A/tree/sub/b.txt").path) }
        let result = Answers()
            .run(
                .move,
                [tree],
                to: TargetSpec(directory: base.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: probe)
            )
        #expect(result.completed == [tree])
        #expect(treeAtCommit && base.commits == ["/out"])
        #expect(!box.exists("A/tree"))
        #expect(base.contents("/out/tree/sub/b.txt") == "b")
    }

    /// A failed commit keeps every source and ends the job as failed, also after Retry.
    @Test
    internal func aFailedCommitKeepsEverySourceAndEndsTheJobAsFailed() throws {
        let box = try Sandbox()
        let files = try (1...3).map { try box.file("A/f\($0).txt", "content \($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        base.commitFailure = CocoaError(.fileWriteOutOfSpace)
        let retry = RetryOnce()
        let job = FileJob(
            kind: .move,
            sources: files,
            target: TargetSpec(directory: base.url("/out")),
            fileSystems: FileSystemRegistry.localDisk(and: probe)
        )
        job.delegate = retry
        let result = withExtendedLifetime(retry) { job.run() }
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(result.completed.isEmpty && result.cancelled && result.failureCount >= 1)
        // Retry asked the same question again; it never deleted anything, and the commit ran once.
        #expect(retry.errors.count == 2)
        #expect(base.commits == ["/out"])
    }

    /// A target without deferred writes is not committed, and the sources go at once.
    @Test
    internal func aTargetWithoutDeferredWritesIsNotCommittedAndSourcesGoAtOnce() throws {
        let box = try Sandbox()
        let files = try (1...3).map { try box.file("A/f\($0).txt", "c\($0)") }
        let (base, probe) = destination([.write])
        let result = Answers()
            .run(
                .move,
                files,
                to: TargetSpec(directory: base.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: probe)
            )
        #expect(base.commits.isEmpty)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(result.completed.count == 3)
    }

    /// A move of many files is committed in batches.
    @Test
    internal func aHugeMoveIsCommittedInBatches() throws {
        let box = try Sandbox()
        let files = try (1...7).map { try box.file("A/f\($0).txt", "c\($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        Replies()
            .run(
                .move,
                files,
                to: TargetSpec(directory: base.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: probe)
            ) { job in
                job.deferredBatchSize = 2
                // One file at a time, so that the count of waiting removals is the same on every run.
                job.parallelWidth = 1
            }
        #expect(base.commits.count >= 3)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect((1...7).allSatisfy { base.contents("/out/f\($0).txt") == "c\($0)" })
    }

    /// A commit in the middle of a move never meets a file under its temporary name.
    @Test
    internal func aCommitInTheMiddleOfAMoveMeetsNoFileUnderItsTemporaryName() throws {
        let box = try Sandbox()
        let files = try (1...16).map { try box.file("A/f\($0).txt", "c\($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        let seen = Locked<[String]>([])
        // A file waits a moment between being written and getting its name.
        probe.onMove = { Thread.sleep(forTimeInterval: 0.01) }
        probe.onCommit = { seen.modify { $0 += base.allPaths.filter { $0.contains(".afm-") } } }
        Replies()
            .run(
                .move,
                files,
                to: TargetSpec(directory: base.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: probe)
            ) { job in
                job.deferredBatchSize = 2
                job.parallelWidth = 4
            }
        #expect(base.commits.count >= 2)
        #expect(seen.value.isEmpty)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect((1...16).allSatisfy { base.contents("/out/f\($0).txt") == "c\($0)" })
    }

    /// A source that could not be removed after the commit is not reported as moved.
    @Test
    internal func aSourceThatCouldNotBeRemovedIsNotReportedAsMoved() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/a.txt", "a")
        let (base, probe) = destination([.write, .deferredWrites])
        // The file cannot be deleted: its folder stays, and so does the item in the panel.
        #expect(chflags(box.url("A/tree/a.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(box.url("A/tree/a.txt").path, 0) }
        let result = Replies()
            .run(
                .move,
                [tree],
                to: TargetSpec(directory: base.url("/out")),
                fileSystems: FileSystemRegistry.localDisk(and: probe),
                configure: nil
            )
        #expect(result.completed.isEmpty)
        #expect(box.exists("A/tree/a.txt"))
    }
}
