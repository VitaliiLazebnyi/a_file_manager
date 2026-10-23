import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Jobs between two file systems, and on a file system that is not the local disk.
@Suite
internal struct CrossFileSystemJobs {
    /// Files and folders go from the disk into another file system with date and permissions.
    @Test
    internal func copiesFromDiskIntoAnotherFileSystem() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try box.file("A/one.txt", "1", modified: stamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: source.path)
        try box.file("A/docs/deep/three.txt", "3")
        memory.addDirectory("/inbox")
        let result = Answers()
            .run(
                .copy,
                [box.url("A/one.txt"), box.url("A/docs")],
                to: TargetSpec(directory: memory.url("/inbox")),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 2)
        #expect(memory.contents("/inbox/one.txt") == "1")
        #expect(memory.contents("/inbox/docs/deep/three.txt") == "3")
        // Date and permissions travel with the file.
        #expect(memory.item(at: memory.url("/inbox/one.txt"))?.modified == stamp)
        #expect(memory.item(at: memory.url("/inbox/one.txt"))?.permissions == 0o750)
        #expect(box.exists("A/one.txt"))
        #expect(
            memory.allPaths == [
                "/inbox", "/inbox/docs", "/inbox/docs/deep", "/inbox/docs/deep/three.txt", "/inbox/one.txt"
            ]
        )
    }

    /// Files and folders come from another file system onto the disk with date and permissions.
    @Test
    internal func copiesFromAnotherFileSystemOntoDisk() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        memory.addFile("/out/report.txt", "from memory", modified: stamp, permissions: 0o600)
        memory.addFile("/out/sub/nested.txt", "n")
        try box.folder("B")
        let result = Answers()
            .run(.copy, [memory.url("/out")], to: TargetSpec(directory: box.url("B")), fileSystems: fileSystems)
        #expect(result.completed.count == 1)
        #expect(box.read("B/out/report.txt") == "from memory")
        #expect(box.read("B/out/sub/nested.txt") == "n")
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("B/out/report.txt").path)
        #expect(attributes[.modificationDate] as? Date == stamp)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(namesOnDisk(box.url("B/out")) == ["report.txt", "sub"])
    }

    /// Moving between file systems copies and then removes the source.
    @Test
    internal func movingBetweenFileSystemsRemovesTheSource() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.file("A/docs/one.txt", "1")
        try box.file("A/solo.txt", "s")
        memory.addDirectory("/inbox")
        let result = Answers()
            .run(
                .move,
                [box.url("A/docs"), box.url("A/solo.txt")],
                to: TargetSpec(directory: memory.url("/inbox")),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 2)
        #expect(!box.exists("A/docs") && !box.exists("A/solo.txt"))
        #expect(memory.contents("/inbox/docs/one.txt") == "1" && memory.contents("/inbox/solo.txt") == "s")
    }

    /// Overwriting on another file system leaves only the new file there.
    @Test
    internal func overwritingOnAnotherFileSystemGoesThroughATemporaryName() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.file("A/one.txt", "new")
        memory.addFile("/inbox/one.txt", "old")
        let answers = Answers()
        answers.run(
            .copy,
            [box.url("A/one.txt")],
            to: TargetSpec(directory: memory.url("/inbox")),
            fileSystems: fileSystems
        )
        #expect(answers.conflicts == ["one.txt"])
        #expect(memory.contents("/inbox/one.txt") == "new")
        #expect(memory.allPaths == ["/inbox", "/inbox/one.txt"])
    }

    /// A copy stopped in the middle of a stream leaves neither the file nor its temporary name.
    @Test
    internal func aCancelledStreamLeavesNothingBehind() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.file("A/big.bin", String(repeating: "x", count: 5 << 20))
        memory.addDirectory("/inbox")
        let answers = Answers()
        answers.cancelAtBytes = 2 << 20
        let result = answers.run(
            .copy,
            [box.url("A/big.bin")],
            to: TargetSpec(directory: memory.url("/inbox")),
            fileSystems: fileSystems
        )
        #expect(result.cancelled)
        // Neither the file nor its temporary name remains.
        #expect(memory.allPaths == ["/inbox"])
        #expect(Set(answers.progress.map(\.bytesDone)).count > 2)
    }

    /// Within one file system the job uses its own copy, move and delete, with progress.
    @Test
    internal func jobsWithinAnotherFileSystemUseItsOwnOperations() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/one.txt", String(repeating: "1", count: 3_000))
        memory.addFile("/a/docs/two.txt", "2")
        memory.addDirectory("/b")
        memory.copyBlockSize = 1_000
        let answers = Answers()
        answers.run(
            .copy,
            [memory.url("/a/one.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            fileSystems: fileSystems
        )
        #expect(memory.contents("/b/one.txt")?.count == 3_000)
        #expect(answers.progress.map(\.bytesDone).contains(2_000))

        Answers()
            .run(.move, [memory.url("/a/docs")], to: TargetSpec(directory: memory.url("/b")), fileSystems: fileSystems)
        #expect(memory.contents("/b/docs/two.txt") == "2" && !memory.exists("/a/docs"))

        let skip = Answers()
        skip.folderDelete = .skip
        skip.run(.delete(toTrash: false), [memory.url("/b/docs")], to: nil, fileSystems: fileSystems)
        #expect(memory.exists("/b/docs/two.txt"))
        Answers()
            .run(
                .delete(toTrash: false),
                [memory.url("/b/docs"), memory.url("/b/one.txt")],
                to: nil,
                fileSystems: fileSystems
            )
        #expect(memory.allPaths == ["/a", "/a/one.txt", "/b"])
    }

    /// A file system that cannot copy by itself gets the file streamed through the job.
    @Test
    internal func aFileSystemThatCannotCopyByItselfIsStreamed() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/serverA/data.bin", String(repeating: "d", count: 2_000), permissions: 0o640)
        memory.addDirectory("/serverB")
        memory.refusesInternalCopy = true
        let result = Answers()
            .run(
                .copy,
                [memory.url("/serverA/data.bin")],
                to: TargetSpec(directory: memory.url("/serverB")),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 1)
        #expect(memory.contents("/serverB/data.bin")?.count == 2_000)
        #expect(memory.item(at: memory.url("/serverB/data.bin"))?.permissions == 0o640)
        #expect(memory.allPaths == ["/serverA", "/serverA/data.bin", "/serverB", "/serverB/data.bin"])
    }

    /// A folder that cannot be listed is neither moved nor deleted, whatever the answer.
    @Test
    internal func anUnreadableFolderIsNotMovedAwayOrDeleted() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/precious.txt", "p")
        memory.addDirectory("/b/docs")
        memory.unreadable = ["/a/docs"]
        for failure in [ErrorChoice.skip, .skipAll] {
            let answers = Answers()
            answers.failure = failure
            #expect(
                answers.run(
                    .move,
                    [memory.url("/a/docs")],
                    to: TargetSpec(directory: memory.url("/b")),
                    fileSystems: fileSystems
                )
                .completed.isEmpty
            )
            #expect(
                answers.run(.delete(toTrash: false), [memory.url("/a/docs")], to: nil, fileSystems: fileSystems)
                    .completed.isEmpty
            )
        }
        #expect(memory.contents("/a/docs/precious.txt") == "p")
    }

    /// A volume without a Trash: the job asks whether to delete for good (the stand-in
    /// delegate agrees, as it does to every protection question).
    @Test
    internal func trashWhereThereIsNoneOffersToDeleteForGood() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/one.txt")
        let answers = Answers()
        let result = answers.run(.delete(toTrash: true), [memory.url("/a/one.txt")], to: nil, fileSystems: fileSystems)
        #expect(result.completed == [memory.url("/a/one.txt")])
        #expect(answers.errors.isEmpty && !memory.exists("/a/one.txt"))
    }
}
