import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Jobs on the local disk.
@Suite
internal struct LocalJobs {
    /// Files and whole folders are copied, with progress over every item and byte.
    @Test
    internal func copiesFilesAndFoldersRecursively() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/docs/two.txt", "2")
        try box.file("A/docs/deep/three.txt", "3")
        try box.folder("B")
        let answers = Answers()
        let result = answers.run(
            .copy,
            [box.url("A/one.txt"), box.url("A/docs")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        #expect(result.completed.count == 2)
        #expect(!result.cancelled)
        #expect(box.read("B/one.txt") == "1")
        #expect(box.read("B/docs/deep/three.txt") == "3")
        #expect(box.exists("A/docs/two.txt"))
        #expect(answers.progress.last?.itemsTotal == 5)
        #expect(answers.progress.last?.bytesTotal == 3)
        #expect(answers.progress.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
        #expect(answers.progress.first?.lines == ["From: \(box.url("A/docs").path)", "To: \(box.url("B/docs").path)"])
    }

    /// A job that has run is freed once nothing holds it.
    @Test
    internal func aFinishedJobIsLetGo() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt", "1")
        try box.folder("B")
        let (fileSystems, _) = makeFileSystems()
        weak var finished: FileJob?
        do {
            // Without a delegate, the lines of the last item are never shown.
            let job = FileJob(
                kind: .copy,
                sources: [box.url("A/docs")],
                target: TargetSpec(directory: box.url("B")),
                fileSystems: fileSystems
            )
            #expect(job.run().completed.count == 1)
            finished = job
        }
        #expect(finished == nil)
    }

    /// Copying over an existing file leaves only the final names in the target.
    @Test
    internal func noTemporaryNamesAreLeftBehind() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        try box.file("B/two.txt", "old")
        Answers()
            .run(
                .copy,
                [box.url("A/one.txt"), box.url("A/two.txt")],
                to: TargetSpec(directory: box.url("B")),
                fileSystems: makeFileSystems().0
            )
        #expect(namesOnDisk(box.url("B")) == ["one.txt", "two.txt"])
        #expect(box.read("B/two.txt") == "2")
    }

    /// A target folder that does not exist yet is made, with the folders above it.
    @Test
    internal func createsMissingTargetFolders() throws {
        let box = try Sandbox()
        try box.folder("A/docs")
        Answers()
            .run(
                .copy,
                [box.url("A/docs")],
                to: TargetSpec(directory: box.url("B/new/sub")),
                fileSystems: makeFileSystems().0
            )
        #expect(box.exists("B/new/sub/docs"))
    }

    /// A copy keeps the modification date and the permissions of its source.
    @Test
    internal func copyKeepsTimeAndPermissions() throws {
        let box = try Sandbox()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try box.file("A/tool.sh", "#!/bin/sh", modified: stamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try box.folder("B")
        Answers().run(.copy, [source], to: TargetSpec(directory: box.url("B")), fileSystems: makeFileSystems().0)
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("B/tool.sh").path)
        #expect(attributes[.modificationDate] as? Date == stamp)
        #expect(attributes[.posixPermissions] as? Int == 0o755)
    }

    /// The answer to an existing name decides: skip all leaves every target, overwrite replaces each.
    @Test
    internal func overwriteAndSkip() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("A/two.txt", "new")
        try box.file("B/one.txt", "old")
        try box.file("B/two.txt", "old")
        let sources = [box.url("A/one.txt"), box.url("A/two.txt")]

        let skip = Answers()
        skip.conflict = .skipAll
        let skipped = skip.run(
            .copy,
            sources,
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        #expect(skip.conflicts == ["one.txt"])
        #expect(skipped.completed.isEmpty)
        #expect(box.read("B/two.txt") == "old")

        let overwrite = Answers()
        let replaced = overwrite.run(
            .copy,
            sources,
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        #expect(overwrite.conflicts == ["one.txt", "two.txt"])
        #expect(replaced.completed.count == 2)
        #expect(box.read("B/one.txt") == "new")
        #expect(namesOnDisk(box.url("B")) == ["one.txt", "two.txt"])
    }

    /// Overwrite all older replaces only targets that are older than their source.
    @Test
    internal func overwriteAllOlderKeepsNewerTargets() throws {
        let box = try Sandbox()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        try box.file("A/one.txt", "source", modified: new)
        try box.file("A/two.txt", "source", modified: old)
        try box.file("B/one.txt", "target", modified: old)
        try box.file("B/two.txt", "target", modified: new)
        let answers = Answers()
        answers.conflict = .overwriteAllOlder
        answers.run(
            .copy,
            [box.url("A/one.txt"), box.url("A/two.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        #expect(box.read("B/one.txt") == "source")
        #expect(box.read("B/two.txt") == "target")
    }

    /// Cancel at a question stops the job before anything else is written.
    @Test
    internal func cancelStopsTheJob() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("A/two.txt", "new")
        try box.file("B/one.txt", "old")
        let answers = Answers()
        answers.conflict = .cancel
        let result = answers.run(
            .copy,
            [box.url("A/one.txt"), box.url("A/two.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        )
        #expect(result.cancelled)
        #expect(box.read("B/one.txt") == "old")
        #expect(namesOnDisk(box.url("B")) == ["one.txt"])
    }

    /// A job without a delegate stops at its first question instead of guessing.
    @Test
    internal func aJobWithoutAnyoneToAskStopsAtItsFirstQuestion() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        try box.file("A/one.txt", "new")
        try box.file("B/one.txt", "old")
        // No delegate: the job must not guess an answer.
        let job = FileJob(
            kind: .copy,
            sources: [box.url("A/one.txt")],
            target: TargetSpec(directory: box.url("B")),
            fileSystems: fileSystems
        )
        #expect(job.run().cancelled)
        #expect(box.read("B/one.txt") == "old")
    }

    /// Copying a file onto itself or a folder into itself is refused.
    @Test
    internal func copyOntoItselfIsRefused() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        try box.file("A/one.txt", "1")
        let job = FileJob(
            kind: .copy,
            sources: [box.url("A/one.txt")],
            target: TargetSpec(directory: box.url("A")),
            fileSystems: fileSystems
        )
        #expect(job.targetsSourceFolder)
        #expect(
            !FileJob(
                kind: .delete(toTrash: false),
                sources: [box.url("A/one.txt")],
                target: nil,
                fileSystems: fileSystems
            )
            .targetsSourceFolder
        )
        let answers = Answers()
        answers.run(
            .copy,
            [box.url("A")],
            to: TargetSpec(directory: box.url("A/sub")),
            fileSystems: makeFileSystems().0
        )
        #expect(answers.errors.count == 1)
        #expect(!box.exists("A/sub"))
    }

    /// A copy can take a new name or a mask in its own folder.
    @Test
    internal func copyWithRenameAndMask() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        Answers()
            .run(
                .copy,
                [box.url("A/one.txt")],
                to: TargetSpec(directory: box.url("A"), mask: "copy.txt"),
                fileSystems: makeFileSystems().0
            )
        #expect(box.read("A/copy.txt") == "1")
        Answers()
            .run(
                .copy,
                [box.url("A/one.txt"), box.url("A/two.txt")],
                to: TargetSpec(directory: box.url("A"), mask: "*.bak"),
                fileSystems: makeFileSystems().0
            )
        #expect(box.read("A/two.bak") == "2")
    }

    /// Pasting into the source folder gives the copies free names instead of refusing.
    @Test
    internal func pasteIntoTheSameFolderRenamesTheCopy() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        try box.file("A/one.txt", "1")
        try box.file("A/docs/in.txt", "2")
        let job = FileJob(
            kind: .copy,
            sources: [box.url("A/one.txt"), box.url("A/docs")],
            target: TargetSpec(directory: box.url("A")),
            fileSystems: fileSystems
        )
        job.renamesSelfCopies = true
        #expect(!job.targetsSourceFolder)
        #expect(job.run().completed.count == 2)
        #expect(box.read("A/one (2).txt") == "1")
        #expect(box.read("A/docs (2)/in.txt") == "2")
    }
}
