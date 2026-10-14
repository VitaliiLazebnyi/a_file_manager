import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@Suite struct Targets {
    @Test func wildcardTargetNames() {
        // The examples of spec 07 › Wildcard target names.
        #expect(TargetMask.apply("h?.txt", to: "test.txt") == "he.txt")
        #expect(TargetMask.apply("f*.txt", to: "test.txt") == "fest.txt")
        #expect(TargetMask.apply("F*Rest.*", to: "test.txt") == "FestRest.txt")
        #expect(TargetMask.apply("start_**_rest.*", to: "test.txt") == "start_test_rest.txt")
        #expect(TargetMask.apply("start_*?do*_rest.*", to: "name.txt") == "start_dome_rest.txt")
        #expect(TargetMask.apply("*.new", to: "a.txt") == "a.new")
        #expect(TargetMask.apply("*.*", to: "a.txt") == "a.txt")
        #expect(TargetMask.apply("renamed.md", to: "a.txt") == "renamed.md")
        #expect(TargetMask.apply("plain", to: "a.txt") == "plain")
    }

    @Test func parsesTheTargetField() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.folder("B")
        let source = try box.folder("A")
        func parse(_ text: String, count: Int = 1) -> TargetSpec {
            TargetSpec.parse(text, sourceDirectory: source, operandCount: count, fileSystems: fileSystems)
        }
        #expect(parse(box.url("B").path, count: 3) == TargetSpec(directory: box.url("B")))
        #expect(parse(box.url("B").path + "/*.new", count: 3) == TargetSpec(directory: box.url("B"), mask: "*.new"))
        #expect(parse(box.url("B/copy.txt").path) == TargetSpec(directory: box.url("B"), mask: "copy.txt"))
        #expect(parse("renamed.txt") == TargetSpec(directory: source, mask: "renamed.txt"))
        #expect(parse("*.bak", count: 2) == TargetSpec(directory: source, mask: "*.bak"))
        #expect(parse("..") == TargetSpec(directory: box.root))
        #expect(parse(box.url("new/sub").path + "/") == TargetSpec(directory: box.url("new/sub")))
        #expect(parse(box.url("new/sub").path, count: 2) == TargetSpec(directory: box.url("new/sub")))
        #expect(parse("", count: 2) == TargetSpec(directory: source))
        // A target on another file system is written as a full location.
        memory.addDirectory("/inbox")
        #expect(parse("mem:///inbox", count: 2) == TargetSpec(directory: memory.url("/inbox")))
        #expect(parse("mem:///inbox/new.txt") == TargetSpec(directory: memory.url("/inbox"), mask: "new.txt"))
    }

    @Test func uniqueNames() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        func free(_ name: String) -> String {
            UniqueName.available(for: box.url(name), in: fileSystems).lastPathComponent
        }
        #expect(free("report.txt") == "report.txt")
        try box.file("report.txt")
        #expect(free("report.txt") == "report (2).txt")
        try box.file("report (2).txt")
        try box.folder("docs")
        #expect(free("report.txt") == "report (3).txt")
        #expect(free("docs") == "docs (2)")
    }
}

@Suite struct Wording {
    func item(_ name: String, folder: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: folder)
    }

    @Test func headings() {
        #expect(OperationText.heading("Copy", [item("a.txt")]) == "Copy \"a.txt\" to")
        #expect(OperationText.heading("Copy", [item("docs", folder: true)]) == "Copy 1 file(s) to")
        #expect(OperationText.heading("Rename/Move", [item("a"), item("b")]) == "Rename/Move 2 file(s) to")
    }

    @Test func targetProposals() {
        #expect(
            OperationText.targetProposal(for: [item("a.txt")], targetPath: "/Volumes/Data/B") == "/Volumes/Data/B/a.txt"
        )
        #expect(
            OperationText.targetProposal(for: [item("docs", folder: true)], targetPath: "/Volumes/Data/B")
                == "/Volumes/Data/B/*.*")
        #expect(OperationText.targetProposal(for: [item("a"), item("b")], targetPath: "/") == "/*.*")
        #expect(OperationText.targetProposal(for: [item("docs", folder: true)], targetPath: nil) == "docs")
    }

    @Test func deleteQuestions() {
        #expect(
            OperationText.deleteQuestion([item("a.txt")], toTrash: true)
                == "Do you really want to move the selected file a.txt to the Trash?")
        #expect(
            OperationText.deleteQuestion([item("q", folder: true)], toTrash: false)
                == "Do you really want to delete the selected directory q?")
        #expect(
            OperationText.deleteQuestion([item("a"), item("b")], toTrash: false)
                == "Do you really want to delete the 2 selected files/directories?")
    }

    @Test func formats() {
        #expect(Format.bytes(250_944) == "250,944")
        #expect(Format.kilobytes(0) == "0 k")
        #expect(Format.shortSize(15) == "15 b")
        #expect(Format.shortSize(6_840) == "6.68 k")
        #expect(Format.permissions(0o755) == "rwxr-xr-x")
        #expect(Format.permissions(0o600) == "rw-------")
        #expect(Format.speed(11_600_000) == "11.06 M/s")
        #expect(Format.duration(0.2) == "1 s")
        #expect(Format.duration(78) == "1 min 20 s")
        #expect(Format.duration(3_599) == "1 h 00 min")
        #expect(Format.duration(7_500) == "2 h 05 min")
        // The date follows the user's region; it always shows year and time.
        let date = Format.date(Date(timeIntervalSince1970: 1_700_000_000))
        #expect(date.contains("2023") && date.contains(":"))
    }
}

/// Jobs on the local disk.
@Suite struct LocalJobs {
    @Test func copiesFilesAndFoldersRecursively() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/docs/two.txt", "2")
        try box.file("A/docs/deep/three.txt", "3")
        try box.folder("B")
        let answers = Answers()
        let result = runJob(
            .copy, [box.url("A/one.txt"), box.url("A/docs")], to: TargetSpec(directory: box.url("B")), answers: answers
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

    @Test func aFinishedJobIsLetGo() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt", "1")
        try box.folder("B")
        let (fileSystems, _) = makeFileSystems()
        weak var finished: FileJob?
        do {
            // Without a delegate, the lines of the last item are never shown.
            let job = FileJob(
                kind: .copy, sources: [box.url("A/docs")], target: TargetSpec(directory: box.url("B")),
                fileSystems: fileSystems)
            #expect(job.run().completed.count == 1)
            finished = job
        }
        #expect(finished == nil)
    }

    @Test func noTemporaryNamesAreLeftBehind() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        try box.file("B/two.txt", "old")
        runJob(.copy, [box.url("A/one.txt"), box.url("A/two.txt")], to: TargetSpec(directory: box.url("B")))
        #expect(namesOnDisk(box.url("B")) == ["one.txt", "two.txt"])
        #expect(box.read("B/two.txt") == "2")
    }

    @Test func createsMissingTargetFolders() throws {
        let box = try Sandbox()
        try box.folder("A/docs")
        runJob(.copy, [box.url("A/docs")], to: TargetSpec(directory: box.url("B/new/sub")))
        #expect(box.exists("B/new/sub/docs"))
    }

    @Test func copyKeepsTimeAndPermissions() throws {
        let box = try Sandbox()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try box.file("A/tool.sh", "#!/bin/sh", modified: stamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try box.folder("B")
        runJob(.copy, [source], to: TargetSpec(directory: box.url("B")))
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("B/tool.sh").path)
        #expect(attributes[.modificationDate] as? Date == stamp)
        #expect(attributes[.posixPermissions] as? Int == 0o755)
    }

    @Test func overwriteAndSkip() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("A/two.txt", "new")
        try box.file("B/one.txt", "old")
        try box.file("B/two.txt", "old")
        let sources = [box.url("A/one.txt"), box.url("A/two.txt")]

        let skip = Answers()
        skip.conflict = .skipAll
        let skipped = runJob(.copy, sources, to: TargetSpec(directory: box.url("B")), answers: skip)
        #expect(skip.conflicts == ["one.txt"])
        #expect(skipped.completed.isEmpty)
        #expect(box.read("B/two.txt") == "old")

        let overwrite = Answers()
        let replaced = runJob(.copy, sources, to: TargetSpec(directory: box.url("B")), answers: overwrite)
        #expect(overwrite.conflicts == ["one.txt", "two.txt"])
        #expect(replaced.completed.count == 2)
        #expect(box.read("B/one.txt") == "new")
        #expect(namesOnDisk(box.url("B")) == ["one.txt", "two.txt"])
    }

    @Test func overwriteAllOlderKeepsNewerTargets() throws {
        let box = try Sandbox()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        try box.file("A/one.txt", "source", modified: new)
        try box.file("A/two.txt", "source", modified: old)
        try box.file("B/one.txt", "target", modified: old)
        try box.file("B/two.txt", "target", modified: new)
        let answers = Answers()
        answers.conflict = .overwriteAllOlder
        runJob(
            .copy, [box.url("A/one.txt"), box.url("A/two.txt")], to: TargetSpec(directory: box.url("B")),
            answers: answers)
        #expect(box.read("B/one.txt") == "source")
        #expect(box.read("B/two.txt") == "target")
    }

    @Test func cancelStopsTheJob() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("A/two.txt", "new")
        try box.file("B/one.txt", "old")
        let answers = Answers()
        answers.conflict = .cancel
        let result = runJob(
            .copy, [box.url("A/one.txt"), box.url("A/two.txt")], to: TargetSpec(directory: box.url("B")),
            answers: answers)
        #expect(result.cancelled)
        #expect(box.read("B/one.txt") == "old")
        #expect(namesOnDisk(box.url("B")) == ["one.txt"])
    }

    @Test func aJobWithoutAnyoneToAskStopsAtItsFirstQuestion() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        try box.file("A/one.txt", "new")
        try box.file("B/one.txt", "old")
        // No delegate: the job must not guess an answer.
        let job = FileJob(
            kind: .copy, sources: [box.url("A/one.txt")], target: TargetSpec(directory: box.url("B")),
            fileSystems: fileSystems)
        #expect(job.run().cancelled)
        #expect(box.read("B/one.txt") == "old")
    }

    @Test func copyOntoItselfIsRefused() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        try box.file("A/one.txt", "1")
        let job = FileJob(
            kind: .copy, sources: [box.url("A/one.txt")], target: TargetSpec(directory: box.url("A")),
            fileSystems: fileSystems)
        #expect(job.targetsSourceFolder)
        #expect(
            !FileJob(kind: .delete(toTrash: false), sources: [box.url("A/one.txt")], fileSystems: fileSystems)
                .targetsSourceFolder)
        let answers = Answers()
        runJob(.copy, [box.url("A")], to: TargetSpec(directory: box.url("A/sub")), answers: answers)
        #expect(answers.errors.count == 1)
        #expect(!box.exists("A/sub"))
    }

    @Test func copyWithRenameAndMask() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        runJob(.copy, [box.url("A/one.txt")], to: TargetSpec(directory: box.url("A"), mask: "copy.txt"))
        #expect(box.read("A/copy.txt") == "1")
        runJob(
            .copy, [box.url("A/one.txt"), box.url("A/two.txt")],
            to: TargetSpec(directory: box.url("A"), mask: "*.bak"))
        #expect(box.read("A/two.bak") == "2")
    }

    @Test func pasteIntoTheSameFolderRenamesTheCopy() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        try box.file("A/one.txt", "1")
        try box.file("A/docs/in.txt", "2")
        let job = FileJob(
            kind: .copy, sources: [box.url("A/one.txt"), box.url("A/docs")],
            target: TargetSpec(directory: box.url("A")),
            fileSystems: fileSystems)
        job.renamesSelfCopies = true
        #expect(!job.targetsSourceFolder)
        #expect(job.run().completed.count == 2)
        #expect(box.read("A/one (2).txt") == "1")
        #expect(box.read("A/docs (2)/in.txt") == "2")
    }

    @Test func movesAndMergesFolders() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt", "new")
        try box.file("A/docs/sub/two.txt", "2")
        try box.file("A/solo.txt", "s")
        try box.file("B/docs/one.txt", "old")
        try box.file("B/docs/keep.txt", "k")
        let result = runJob(
            .move, [box.url("A/docs"), box.url("A/solo.txt")], to: TargetSpec(directory: box.url("B")))
        #expect(result.completed.count == 2)
        #expect(!box.exists("A/docs"))
        #expect(!box.exists("A/solo.txt"))
        #expect(box.read("B/docs/one.txt") == "new")
        #expect(box.read("B/docs/sub/two.txt") == "2")
        #expect(box.read("B/docs/keep.txt") == "k")
        #expect(box.read("B/solo.txt") == "s")
    }

    @Test func moveKeepsSkippedSources() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt", "new")
        try box.file("A/docs/two.txt", "2")
        try box.file("B/docs/one.txt", "old")
        let answers = Answers()
        answers.conflict = .skip
        let result = runJob(.move, [box.url("A/docs")], to: TargetSpec(directory: box.url("B")), answers: answers)
        // The folder still holds the skipped file, so it stays; what could move has moved.
        #expect(result.completed.isEmpty)
        #expect(box.read("A/docs/one.txt") == "new" && !box.exists("A/docs/two.txt"))
        #expect(box.read("B/docs/one.txt") == "old" && box.read("B/docs/two.txt") == "2")
    }

    @Test func renameInPlace() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        let result = runJob(
            .move, [box.url("A/one.txt")], to: TargetSpec(directory: box.url("A"), mask: "renamed.md"))
        #expect(result.lastTarget?.lastPathComponent == "renamed.md")
        #expect(!box.exists("A/one.txt"))
        #expect(box.read("A/renamed.md") == "1")
    }

    @Test func deletesTreesItemByItem() throws {
        let box = try Sandbox()
        try box.file("A/docs/one.txt")
        try box.file("A/docs/deep/two.txt")
        try box.file("A/docs/deep/.hidden")
        try box.file("A/solo.txt")
        try box.folder("A/empty")

        let skip = Answers()
        skip.folderDelete = .skip
        let kept = runJob(
            .delete(toTrash: false), [box.url("A/docs"), box.url("A/solo.txt"), box.url("A/empty")], answers: skip)
        #expect(skip.nonEmptyQuestions == ["docs"])
        #expect(kept.completed.count == 2)
        #expect(box.exists("A/docs/one.txt") && !box.exists("A/solo.txt") && !box.exists("A/empty"))

        // Every entry of the tree is counted: docs, one.txt, deep, two.txt, .hidden.
        let answers = Answers()
        let deleted = runJob(.delete(toTrash: false), [box.url("A/docs")], answers: answers)
        #expect(deleted.completed.count == 1 && !box.exists("A/docs"))
        #expect(answers.nonEmptyQuestions == ["docs"])
        #expect(answers.progress.last?.itemsTotal == 5)
        #expect(answers.progress.contains { $0.lines == ["Deleting: \(box.url("A/docs/deep/two.txt").path)"] })
    }

    @Test func aDeleteCanBeCancelledInTheMiddleOfATree() throws {
        let box = try Sandbox()
        for index in 0..<20 { try box.file("A/docs/file\(index).txt") }
        let answers = Answers()
        answers.cancelAtItems = 5
        let result = runJob(.delete(toTrash: false), [box.url("A/docs")], answers: answers)
        #expect(result.cancelled)
        let left = namesOnDisk(box.url("A/docs")).count
        #expect(left > 0 && left < 20)
    }

    @Test func aFolderThatCannotBeReadIsNeverRemoved() throws {
        let box = try Sandbox()
        try box.file("A/docs/precious.txt", "p")
        try box.folder("B/docs")
        let locked = box.url("A/docs").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        // Moving into an existing folder merges, which needs the source's listing; it fails and is skipped.
        let moving = Answers()
        let moved = runJob(.move, [box.url("A/docs")], to: TargetSpec(directory: box.url("B")), answers: moving)
        #expect(moving.errors.count == 1)
        #expect(moved.completed.isEmpty)

        let deleting = Answers()
        let deleted = runJob(.delete(toTrash: false), [box.url("A/docs")], answers: deleting)
        #expect(deleting.errors.count == 1)
        #expect(deleted.completed.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        #expect(box.read("A/docs/precious.txt") == "p")
    }

    @Test func symbolicLinksAreCopiedAndDeletedAsLinks() throws {
        let box = try Sandbox()
        try box.file("real/inside.txt", "i")
        try box.folder("A")
        try box.folder("B")
        try FileManager.default.createSymbolicLink(at: box.url("A/link"), withDestinationURL: box.url("real"))
        runJob(.copy, [box.url("A/link")], to: TargetSpec(directory: box.url("B")))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.url("B/link").path)) != nil)
        runJob(.delete(toTrash: false), [box.url("A/link"), box.url("B/link")])
        #expect(box.exists("real/inside.txt"))
    }

    @Test func aMissingSourceIsReportedAndSkipped() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        let answers = Answers()
        let result = runJob(
            .copy, [box.url("A/gone.txt"), box.url("A/one.txt")], to: TargetSpec(directory: box.url("B")),
            answers: answers)
        #expect(answers.errors.count == 1)
        #expect(result.completed.count == 1)
        #expect(box.read("B/one.txt") == "1")
    }
}

/// Jobs between two file systems, and on a file system that is not the local disk.
@Suite struct CrossFileSystemJobs {
    @Test func copiesFromDiskIntoAnotherFileSystem() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try box.file("A/one.txt", "1", modified: stamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: source.path)
        try box.file("A/docs/deep/three.txt", "3")
        memory.addDirectory("/inbox")
        let result = runJob(
            .copy, [box.url("A/one.txt"), box.url("A/docs")], to: TargetSpec(directory: memory.url("/inbox")),
            fileSystems: fileSystems)
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
            ])
    }

    @Test func copiesFromAnotherFileSystemOntoDisk() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        memory.addFile("/out/report.txt", "from memory", modified: stamp, permissions: 0o600)
        memory.addFile("/out/sub/nested.txt", "n")
        try box.folder("B")
        let result = runJob(
            .copy, [memory.url("/out")], to: TargetSpec(directory: box.url("B")), fileSystems: fileSystems)
        #expect(result.completed.count == 1)
        #expect(box.read("B/out/report.txt") == "from memory")
        #expect(box.read("B/out/sub/nested.txt") == "n")
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("B/out/report.txt").path)
        #expect(attributes[.modificationDate] as? Date == stamp)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(namesOnDisk(box.url("B/out")) == ["report.txt", "sub"])
    }

    @Test func movingBetweenFileSystemsRemovesTheSource() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.file("A/docs/one.txt", "1")
        try box.file("A/solo.txt", "s")
        memory.addDirectory("/inbox")
        let result = runJob(
            .move, [box.url("A/docs"), box.url("A/solo.txt")], to: TargetSpec(directory: memory.url("/inbox")),
            fileSystems: fileSystems)
        #expect(result.completed.count == 2)
        #expect(!box.exists("A/docs") && !box.exists("A/solo.txt"))
        #expect(memory.contents("/inbox/docs/one.txt") == "1" && memory.contents("/inbox/solo.txt") == "s")
    }

    @Test func overwritingOnAnotherFileSystemGoesThroughATemporaryName() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.file("A/one.txt", "new")
        memory.addFile("/inbox/one.txt", "old")
        let answers = Answers()
        runJob(
            .copy, [box.url("A/one.txt")], to: TargetSpec(directory: memory.url("/inbox")), answers: answers,
            fileSystems: fileSystems)
        #expect(answers.conflicts == ["one.txt"])
        #expect(memory.contents("/inbox/one.txt") == "new")
        #expect(memory.allPaths == ["/inbox", "/inbox/one.txt"])
    }

    @Test func aCancelledStreamLeavesNothingBehind() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.file("A/big.bin", String(repeating: "x", count: 5 << 20))
        memory.addDirectory("/inbox")
        let answers = Answers()
        answers.cancelAtBytes = 2 << 20
        let result = runJob(
            .copy, [box.url("A/big.bin")], to: TargetSpec(directory: memory.url("/inbox")), answers: answers,
            fileSystems: fileSystems)
        #expect(result.cancelled)
        // Neither the file nor its temporary name remains.
        #expect(memory.allPaths == ["/inbox"])
        #expect(Set(answers.progress.map(\.bytesDone)).count > 2)
    }

    @Test func jobsWithinAnotherFileSystemUseItsOwnOperations() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/one.txt", String(repeating: "1", count: 3_000))
        memory.addFile("/a/docs/two.txt", "2")
        memory.addDirectory("/b")
        memory.copyBlockSize = 1_000
        let answers = Answers()
        runJob(
            .copy, [memory.url("/a/one.txt")], to: TargetSpec(directory: memory.url("/b")), answers: answers,
            fileSystems: fileSystems)
        #expect(memory.contents("/b/one.txt")?.count == 3_000)
        #expect(answers.progress.map(\.bytesDone).contains(2_000))

        runJob(.move, [memory.url("/a/docs")], to: TargetSpec(directory: memory.url("/b")), fileSystems: fileSystems)
        #expect(memory.contents("/b/docs/two.txt") == "2" && !memory.exists("/a/docs"))

        let skip = Answers()
        skip.folderDelete = .skip
        runJob(.delete(toTrash: false), [memory.url("/b/docs")], answers: skip, fileSystems: fileSystems)
        #expect(memory.exists("/b/docs/two.txt"))
        runJob(.delete(toTrash: false), [memory.url("/b/docs"), memory.url("/b/one.txt")], fileSystems: fileSystems)
        #expect(memory.allPaths == ["/a", "/a/one.txt", "/b"])
    }

    @Test func aFileSystemThatCannotCopyByItselfIsStreamed() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/serverA/data.bin", String(repeating: "d", count: 2_000), permissions: 0o640)
        memory.addDirectory("/serverB")
        memory.refusesInternalCopy = true
        let result = runJob(
            .copy, [memory.url("/serverA/data.bin")], to: TargetSpec(directory: memory.url("/serverB")),
            fileSystems: fileSystems)
        #expect(result.completed.count == 1)
        #expect(memory.contents("/serverB/data.bin")?.count == 2_000)
        #expect(memory.item(at: memory.url("/serverB/data.bin"))?.permissions == 0o640)
        #expect(memory.allPaths == ["/serverA", "/serverA/data.bin", "/serverB", "/serverB/data.bin"])
    }

    @Test func anUnreadableFolderIsNotMovedAwayOrDeleted() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/precious.txt", "p")
        memory.addDirectory("/b/docs")
        memory.unreadable = ["/a/docs"]
        for failure in [ErrorChoice.skip, .skipAll] {
            let answers = Answers()
            answers.failure = failure
            #expect(
                runJob(
                    .move, [memory.url("/a/docs")], to: TargetSpec(directory: memory.url("/b")), answers: answers,
                    fileSystems: fileSystems
                ).completed.isEmpty)
            #expect(
                runJob(.delete(toTrash: false), [memory.url("/a/docs")], answers: answers, fileSystems: fileSystems)
                    .completed.isEmpty)
        }
        #expect(memory.contents("/a/docs/precious.txt") == "p")
    }

    /// A volume without a Trash: the job asks whether to delete for good (the stand-in
    /// delegate agrees, as it does to every protection question).
    @Test func trashWhereThereIsNoneOffersToDeleteForGood() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/one.txt")
        let answers = Answers()
        let result = runJob(
            .delete(toTrash: true), [memory.url("/a/one.txt")], answers: answers, fileSystems: fileSystems)
        #expect(result.completed == [memory.url("/a/one.txt")])
        #expect(answers.errors.isEmpty && !memory.exists("/a/one.txt"))
    }
}
