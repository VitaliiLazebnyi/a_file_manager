import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Part files, aborts, the records a job makes, hostile names, and what arrives of rights and metadata.
@Suite
internal struct Review2FileopsJobPartials {
    /// A scratch folder of its own for each test.
    internal let box: Sandbox

    /// A fresh scratch folder.
    internal init() throws {
        box = try Sandbox()
    }

    // MARK: F024, F073 and what a cancel may remove

    /// Retry after a failed copy whose part file was kept completes the file without a second copy beside it.
    @Test
    internal func aRetryAfterAKeptPartialFileCompletesTheCopy() throws {
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        try box.folder("t")
        flaky.failNextReads(1)
        let replies = Review2Replies()
        replies.failures = [.retry, .skip]
        let job = FileJob(
            kind: .copy,
            sources: [flaky.base.url("/s/big.bin")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.keepsPartialFiles = true
        job.delegate = replies
        let result = job.run()
        #expect(replies.errors == ["the connection broke"])
        #expect(
            result.completed.count == 1 && box.read("t/big.bin") == "0123456789abcdef"
                && namesOnDisk(box.url("t")) == ["big.bin"]
        )
    }

    /// Skip after a failed copy leaves the part file when part files are to be kept.
    @Test
    internal func aSkipAfterAFailedCopyKeepsThePartialFileWhenAskedTo() throws {
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        try box.folder("t")
        flaky.failNextReads(1)
        let job = FileJob(
            kind: .copy,
            sources: [flaky.base.url("/s/big.bin")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.keepsPartialFiles = true
        let replies = Review2Replies()
        job.delegate = replies
        _ = job.run()
        #expect(box.read("t/big.bin") == "0123" && replies.errors.count == 1)
    }

    /// A cancelled or failed overwrite leaves the old file whole, with or without kept part files.
    @Test
    internal func aCancelledOrFailedOverwriteLeavesTheFileThatWasThere() throws {
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        for keepsPartial in [false, true] {
            try box.file("t/big.bin", "the old file")
            let flag = CancellationFlag()
            flaky.afterFirstBlock = { flag.cancel() }
            let job = FileJob(
                kind: .copy,
                sources: [flaky.base.url("/s/big.bin")],
                target: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems,
                cancellation: flag
            )
            job.options.keepsPartialFiles = keepsPartial
            job.options.overwrite = .overwriteAll
            let result = job.run()
            #expect(
                result.cancelled && box.read("t/big.bin") == "the old file" && namesOnDisk(box.url("t")) == ["big.bin"]
            )
            // The same when the copy fails and is retried: the old file is there until the new one is whole.
            flaky.failNextReads(1)
            let replies = Review2Replies()
            replies.failures = [.skip]
            let failing = FileJob(
                kind: .copy,
                sources: [flaky.base.url("/s/big.bin")],
                target: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems
            )
            failing.options.keepsPartialFiles = keepsPartial
            failing.options.overwrite = .overwriteAll
            failing.delegate = replies
            _ = failing.run()
            #expect(box.read("t/big.bin") == "the old file" && namesOnDisk(box.url("t")) == ["big.bin"])
        }
    }

    // MARK: F046, F045, F049, F053, F051, F021

    /// Abort sets the job's cancellation flag too, so that nothing waits on it.
    @Test
    internal func abortAlsoSetsTheJobsOwnFlagSoThatNothingWaitsOnIt() {
        let (fileSystems, memory) = makeFileSystems()
        let flag = CancellationFlag()
        let job = FileJob(
            kind: .copy,
            sources: [memory.url("/gone.txt")],
            target: TargetSpec(directory: box.root),
            fileSystems: fileSystems,
            cancellation: flag
        )
        let replies = Review2Replies()
        replies.failures = [.abort]
        job.delegate = replies
        #expect(job.run().cancelled && flag.isCancelled)
    }

    /// A job makes only the records its filter asks for, and the log's filter agrees with it before and after.
    @Test
    internal func recordsNobodyWantsAreNotMade() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("s/a.txt")
        try box.file("s/sub/b.txt")
        try box.folder("t")
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var verbs: [OperationRecord.Verb] = []
        let job = FileJob(
            kind: .copy,
            sources: [box.url("s")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.wantsRecord = { verb, _ in verb == .makeFolder }
        job.onRecord = { record in lock.withLock { verbs.append(record.verb) } }
        _ = job.run()
        #expect(verbs == [.makeFolder, .makeFolder])
        // What the log's own filter says for a record and before the record is made is the same.
        var configuration = OperationLog.Configuration()
        configuration.logsFolders = false
        #expect(!configuration.wants(.makeFolder, .done) && configuration.wants(.copy, .skipped))
        #expect(configuration.wants(OperationRecord(.copy, source: "a")) == configuration.wants(.copy, .done))
    }

    /// A source whose last name is .. is refused by copy, move and delete alike.
    @Test
    internal func aSourceWhoseNameLeadsOutOfItsFolderIsRefused() throws {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/A/keep.txt", "keep")
        memory.addDirectory("/B")
        let hostile = try #require(URL(string: memory.url("/A").absoluteString + "/.."))
        #expect(hostile.lastPathComponent == "..")
        for kind in [JobKind.copy, .move, .delete(toTrash: false)] {
            let replies = Review2Replies()
            let job = FileJob(
                kind: kind,
                sources: [hostile],
                target: kind == .delete(toTrash: false) ? nil : TargetSpec(directory: memory.url("/B")),
                fileSystems: fileSystems
            )
            job.delegate = replies
            let result = job.run()
            #expect(result.completed.isEmpty && replies.errors.count == 1 && memory.contents("/A/keep.txt") == "keep")
        }
        #expect((try? memory.list(memory.url("/B"), showHidden: true))?.isEmpty == true)
    }

    /// Rights from another file system arrive on the disk under the umask, and anywhere without the special bits.
    @Test
    internal func rightsFromAnotherFileSystemArriveWithoutSpecialBitsAndUnderTheUmask() throws {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/s/tool", "#!", permissions: 0o6777)
        memory.addFile("/s/plain.txt", "x", permissions: 0o640)
        try box.folder("t")
        Answers()
            .run(
                .copy,
                [memory.url("/s/tool"), memory.url("/s/plain.txt")],
                to: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems
            )
        let mask = umask(0o022)
        umask(mask)
        #expect(Review2Stat.mode(box.url("t/tool")) == 0o777 & ~UInt16(mask))
        #expect(Review2Stat.mode(box.url("t/plain.txt")) == 0o640 & ~UInt16(mask))
        // To a file system that is not the local disk, only the three special bits stay behind.
        memory.addFile("/odd/tool", "#!", permissions: 0o4755)
        let other = MemoryFileSystem(scheme: "other")
        fileSystems.register(other)
        other.addDirectory("/t")
        Answers()
            .run(.copy, [memory.url("/odd/tool")], to: TargetSpec(directory: other.url("/t")), fileSystems: fileSystems)
        #expect(other.item(at: other.url("/t/tool"))?.permissions == 0o755)
    }

    // F050
    /// A locked source of a move to another file system is asked about once, like a delete, and then moved.
    @Test
    internal func aLockedSourceOfAMoveToAnotherFileSystemIsAskedAboutLikeADelete() throws {
        let (fileSystems, memory) = makeFileSystems()
        let file = try box.file("s/locked.txt", "contents")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        memory.addDirectory("/t")
        let replies = Review2Replies()
        let job = FileJob(
            kind: .move,
            sources: [file],
            target: TargetSpec(directory: memory.url("/t")),
            fileSystems: fileSystems
        )
        job.delegate = replies
        let result = job.run()
        #expect(replies.locked == 1 && replies.errors.isEmpty && result.completed.count == 1)
        #expect(memory.contents("/t/locked.txt") == "contents" && !box.exists("s/locked.txt"))
    }

    // F054
    /// An appended file gets the tags, rights and creation date the old file had.
    @Test
    internal func anAppendedFileKeepsWhatTheOldOneCarriedBesidesItsContents() throws {
        let (fileSystems, memory) = makeFileSystems()
        try box.file("s/log.txt", "-more")
        memory.addFile("/t/log.txt", "start")
        memory.keepsMetadata = true
        let replies = Review2Replies()
        replies.conflict = .append
        let job = FileJob(
            kind: .copy,
            sources: [box.url("s/log.txt")],
            target: TargetSpec(directory: memory.url("/t")),
            fileSystems: fileSystems
        )
        job.delegate = replies
        _ = job.run()
        #expect(memory.contents("/t/log.txt") == "start-more" && replies.errors.isEmpty)
        // Tags, access rules and the date of creation of the old file were handed to the new one.
        #expect(memory.metadataCopies.contains { $0.from.path == "/t/log.txt" })
    }
}
