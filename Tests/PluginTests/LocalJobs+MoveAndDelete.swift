import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Moves, renames and deletes on the local disk.
extension LocalJobs {
    /// Moving a folder onto one of the same name merges them; the sources go.
    @Test
    internal func movesAndMergesFolders() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt", "new")
        try box.file("A/docs/sub/two.txt", "2")
        try box.file("A/solo.txt", "s")
        try box.file("B/docs/one.txt", "old")
        try box.file("B/docs/keep.txt", "k")
        let result = Answers()
            .run(
                .move,
                [box.url("A/docs"), box.url("A/solo.txt")],
                to: TargetSpec(directory: box.url("B")),
                fileSystems: makeFileSystems().0
            )
        #expect(result.completed.count == 2)
        #expect(!box.exists("A/docs"))
        #expect(!box.exists("A/solo.txt"))
        #expect(box.read("B/docs/one.txt") == "new")
        #expect(box.read("B/docs/sub/two.txt") == "2")
        #expect(box.read("B/docs/keep.txt") == "k")
        #expect(box.read("B/solo.txt") == "s")
    }

    /// A move leaves skipped files and the folders that hold them where they were.
    @Test
    internal func moveKeepsSkippedSources() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt", "new")
        try box.file("A/docs/two.txt", "2")
        try box.file("B/docs/one.txt", "old")
        let answers = Answers()
        answers.conflict = .skip
        let result = answers.run(
            .move,
            [box.url("A/docs")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        // The folder still holds the skipped file, so it stays; what could move has moved.
        #expect(result.completed.isEmpty)
        #expect(box.read("A/docs/one.txt") == "new" && !box.exists("A/docs/two.txt"))
        #expect(box.read("B/docs/one.txt") == "old" && box.read("B/docs/two.txt") == "2")
    }

    /// A move with a name in the same folder renames the file.
    @Test
    internal func renameInPlace() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        let result = Answers()
            .run(
                .move,
                [box.url("A/one.txt")],
                to: TargetSpec(directory: box.url("A"), mask: "renamed.md"),
                fileSystems: makeFileSystems().0
            )
        #expect(result.lastTarget?.lastPathComponent == "renamed.md")
        #expect(!box.exists("A/one.txt"))
        #expect(box.read("A/renamed.md") == "1")
    }

    /// A delete goes through a tree item by item, asking once about each non-empty folder.
    @Test
    internal func deletesTreesItemByItem() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt")
        try box.file("A/docs/deep/two.txt")
        try box.file("A/docs/deep/.hidden")
        try box.file("A/solo.txt")
        try box.folder("A/empty")

        let skip = Answers()
        skip.folderDelete = .skip
        let kept = skip.run(
            .delete(toTrash: false),
            [box.url("A/docs"), box.url("A/solo.txt"), box.url("A/empty")],
            to: nil,
            fileSystems: makeFileSystems().0
        )
        #expect(skip.nonEmptyQuestions == ["docs"])
        #expect(kept.completed.count == 2)
        #expect(box.exists("A/docs/one.txt") && !box.exists("A/solo.txt") && !box.exists("A/empty"))

        // Every entry of the tree is counted: docs, one.txt, deep, two.txt, .hidden.
        let answers = Answers()
        let deleted = answers.run(
            .delete(toTrash: false),
            [box.url("A/docs")],
            to: nil,
            fileSystems: makeFileSystems().0
        )
        #expect(deleted.completed.count == 1 && !box.exists("A/docs"))
        #expect(answers.nonEmptyQuestions == ["docs"])
        #expect(answers.progress.last?.itemsTotal == 5)
        #expect(answers.progress.contains { $0.lines == ["Deleting: \(box.url("A/docs/deep/two.txt").path)"] })
    }

    /// A delete stopped in the middle of a tree leaves the rest.
    @Test
    internal func aDeleteCanBeCancelledInTheMiddleOfATree() throws {
        let box = try Sandbox()
        for index in 0..<20 { try box.file("A/docs/file\(index).txt") }
        let answers = Answers()
        answers.cancelAtItems = 5
        let result = answers.run(
            .delete(toTrash: false),
            [box.url("A/docs")],
            to: nil,
            fileSystems: makeFileSystems().0
        )
        #expect(result.cancelled)
        let left = namesOnDisk(box.url("A/docs")).count
        #expect(left > 0 && left < 20)
    }

    /// A folder whose listing cannot be read is neither moved away nor deleted.
    @Test
    internal func aFolderThatCannotBeReadIsNeverRemoved() throws {
        let box = try Sandbox()
        try box.file("A/docs/precious.txt", "p")
        try box.folder("B/docs")
        let locked = box.url("A/docs").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        // Moving into an existing folder merges, which needs the source's listing; it fails and is skipped.
        let moving = Answers()
        let moved = moving.run(
            .move,
            [box.url("A/docs")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        #expect(moving.errors.count == 1)
        #expect(moved.completed.isEmpty)

        let deleting = Answers()
        let deleted = deleting.run(
            .delete(toTrash: false),
            [box.url("A/docs")],
            to: nil,
            fileSystems: makeFileSystems().0
        )
        #expect(deleting.errors.count == 1)
        #expect(deleted.completed.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        #expect(box.read("A/docs/precious.txt") == "p")
    }

    /// Symbolic links are copied and deleted as links, never what they point to.
    @Test
    internal func symbolicLinksAreCopiedAndDeletedAsLinks() throws {
        let box = try Sandbox()
        try box.file("real/inside.txt", "i")
        try box.folder("A")
        try box.folder("B")
        try FileManager.default.createSymbolicLink(at: box.url("A/link"), withDestinationURL: box.url("real"))
        Answers()
            .run(.copy, [box.url("A/link")], to: TargetSpec(directory: box.url("B")), fileSystems: makeFileSystems().0)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.url("B/link").path)) != nil)
        Answers()
            .run(
                .delete(toTrash: false),
                [box.url("A/link"), box.url("B/link")],
                to: nil,
                fileSystems: makeFileSystems().0
            )
        #expect(box.exists("real/inside.txt"))
    }

    /// A source that is gone is reported, and the others are still copied.
    @Test
    internal func aMissingSourceIsReportedAndSkipped() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        let answers = Answers()
        let result = answers.run(
            .copy,
            [box.url("A/gone.txt"), box.url("A/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        #expect(answers.errors.count == 1)
        #expect(result.completed.count == 1)
        #expect(box.read("B/one.txt") == "1")
    }
}
