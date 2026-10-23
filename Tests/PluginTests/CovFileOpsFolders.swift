import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Folders copied and moved on the disk where the names meet: the folder under another letter case, a file where
/// the folder goes, two folders of one name, merges answered for all or cancelled, a filter that makes folders with
/// their first file, links followed that lead nowhere, renames onto the file itself.
@Suite
internal struct CovFileOpsFolders {
    private let box: Sandbox
    private let fileSystems = FileSystemRegistry()

    /// A sandbox and a registry with the disk.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
    }

    /// A folder copied onto itself under another letter case is refused; moved, it is renamed.
    @Test
    internal func aFolderUnderAnotherCase() throws {
        try box.file("dir/f.txt", "f")
        let answers = CovFileOpsAnswers()
        let target = TargetSpec(directory: box.root, exactName: "DIR")
        var job = FileJob(kind: .copy, sources: [box.url("dir")], target: target, fileSystems: fileSystems)
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.contains { $0.hasPrefix("failed: dir") })
        job = FileJob(kind: .move, sources: [box.url("dir")], target: target, fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().completed.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path) == ["DIR"])
    }

    /// A folder copied where a file has its name is refused.
    @Test
    internal func aFileWhereTheFolderGoes() throws {
        try box.file("A/same/f.txt", "f")
        try box.file("B/same", "a file")
        let answers = CovFileOpsAnswers()
        let job = FileJob(
            kind: .copy,
            sources: [box.url("A/same")],
            target: TargetSpec(directory: box.url("B")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.contains { $0.contains("A file with the name") } && box.read("B/same") == "a file")
    }

    /// Two folders of one name moved into one folder: the first is renamed there whole, the second merged into it.
    @Test
    internal func twoFoldersOfOneNameAreMovedIntoOne() throws {
        try box.file("x/a/one.txt", "1")
        try box.file("y/a/two.txt", "2")
        try box.folder("T")
        let result = Answers()
            .run(
                .move,
                [box.url("x/a"), box.url("y/a")],
                to: TargetSpec(directory: box.url("T")),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 2 && box.read("T/a/one.txt") == "1" && box.read("T/a/two.txt") == "2")
    }

    /// Merges are asked about when wanted: answered for all, then cancelled.
    @Test
    internal func mergesAnsweredForAllOrCancelled() throws {
        for name in ["a", "b"] {
            try box.file("S/\(name)/new.txt", "new")
            try box.file("T/\(name)/old.txt", "old")
        }
        let answers = CovFileOpsAnswers()
        answers.merges.value = [.mergeAll]
        var job = FileJob(
            kind: .copy,
            sources: [box.url("S/a"), box.url("S/b")],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.options.asksBeforeMerging = true
        job.delegate = answers
        #expect(job.run().completed.count == 2 && answers.asked.value.filter { $0.hasPrefix("merge") }.count == 1)
        answers.merges.value = [.cancel]
        job = FileJob(
            kind: .copy,
            sources: [box.url("S/a")],
            target: TargetSpec(directory: box.url("U")),
            fileSystems: fileSystems
        )
        try box.file("U/a/old.txt", "old")
        job.options.asksBeforeMerging = true
        job.delegate = answers
        #expect(job.run().cancelled)
    }

    /// With a filter that makes folders only for files, a folder is made with its first file and found by the
    /// second.
    @Test
    internal func aFilterMakesAFolderWithItsFirstFile() throws {
        try box.file("S/d/one.txt", "1")
        try box.file("S/d/two.txt", "2")
        try box.file("S/d/skip.bin", "b")
        let job = FileJob(
            kind: .copy,
            sources: [box.url("S/d")],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.options.filter = CopyFilter("*.txt | **/")
        job.options.copiesSmallFilesInParallel = false
        let answers = Answers()
        job.delegate = answers
        _ = withExtendedLifetime(answers) { job.run() }
        #expect(box.read("T/d/one.txt") == "1" && box.read("T/d/two.txt") == "2" && !box.exists("T/d/skip.bin"))
    }

    /// A link that leads nowhere is copied as the link it is, also where links are followed.
    @Test
    internal func aLinkThatLeadsNowhereStaysALink() throws {
        try box.folder("S")
        try FileManager.default.createSymbolicLink(
            atPath: box.url("S/dangling").path,
            withDestinationPath: "/afm-nowhere"
        )
        try box.folder("T")
        let job = FileJob(
            kind: .copy,
            sources: [box.url("S/dangling")],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.options.links = .followLinks
        let answers = Answers()
        job.delegate = answers
        _ = withExtendedLifetime(answers) { job.run() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.url("T/dangling").path) == "/afm-nowhere")
    }

    /// A file renamed onto itself under another case, where the volume moves only between volumes when it replaces,
    /// is refused as a copy onto itself.
    @Test
    internal func aRenameOntoItselfThatWouldCrossVolumesIsRefused() throws {
        try box.file("dir/a.txt", "a")
        let registry = FileSystemRegistry()
        registry.register(CovFileOpsExclusiveDisk(refusesReplacing: true))
        let answers = CovFileOpsAnswers()
        let job = FileJob(
            kind: .move,
            sources: [box.url("dir/a.txt")],
            target: TargetSpec(directory: box.url("dir"), exactName: "A.txt"),
            fileSystems: registry
        )
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.contains { $0.hasPrefix("failed: a.txt") } && box.exists("dir/a.txt"))
    }
}
