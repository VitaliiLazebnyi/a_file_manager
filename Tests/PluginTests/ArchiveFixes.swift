import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The defects found in review of the archives, each held down by a test: nothing is lost when a write fails.
@Suite
internal struct ArchiveFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A write that fails leaves the archive untouched and keeps every change for the next attempt, which then
    /// succeeds.
    @Test
    internal func aFailedWriteKeepsEveryChangeForTheNextAttempt() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try write("precious", to: tree.appending(name: "new.txt"))
        try bench.zip.createDirectory(at: tree.appending(name: "made"))
        // The folder cannot be written to: no new file can be put next to the archive.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path) }
        let before = FileSignature.of(archive.path)
        for _ in 0..<2 {
            #expect(bench.store.flushAll(cancellation: nil).count == 1)
            // The archive is untouched, and the member is still there to read.
            #expect(FileSignature.of(archive.path) == before && isSound(archive))
            #expect(try bench.read(tree.appending(name: "new.txt")) == Data("precious".utf8))
            #expect(
                try bench.names(tree).contains("made")
                    && bench.store.archive(at: archive, cancellation: nil).hasPendingChanges
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && isSound(archive))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/new.txt"]).output == "precious")
        #expect(listed(archive).contains("tree/made/"))
    }

    /// A file moved into an archive is in the archive file when the job ends, without a write waiting.
    @Test
    internal func aCopiedFileIsInTheArchiveFileBeforeTheJobIsDone() throws {
        let archive = try makeZip()
        try box.file("in/one.txt", "one")
        try box.file("in/two.txt", String(repeating: "two ", count: 100_000))
        let result = Answers()
            .run(
                .move,
                [box.url("in/one.txt"), box.url("in/two.txt")],
                to: TargetSpec(directory: bench.inside(archive, "tree")),
                fileSystems: bench.fileSystems
            )
        #expect(result.completed.count == 2 && !box.exists("in/one.txt"))
        // Nothing was asked to write: the rename of each file did.
        #expect(try !bench.store.archive(at: archive, cancellation: nil).hasPendingChanges)
        #expect(isSound(archive) && Set(listed(archive)).isSuperset(of: ["tree/one.txt", "tree/two.txt"]))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/two.txt"]).output.count == 400_000)
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".tmp") })
    }

    /// Many threads that write and rename members at once, while others list and read, leave a sound archive with every
    /// file.
    @Test(arguments: [true, false])
    internal func manyThreadsBringFilesInAtOnce(clones: Bool) throws {
        bench.environment.clonesArchives = clones
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let failures = SharedCounter()
        // Each thread does what a copy job does: a temporary name, then the real one. Others
        // list and read meanwhile.
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                if index % 4 == 3 {
                    _ = try bench.names(tree)
                    _ = try bench.read(tree.appending(name: "readme.txt"))
                    return
                }
                let temporary = tree.appending(name: ".afm-\(index).tmp")
                let writer = try bench.zip.write(temporary)
                try writer.write(Data(String(repeating: "file \(index) ", count: 2_000 * (index + 1)).utf8))
                try writer.close(attributes: FileAttributes())
                try bench.zip.move(temporary, to: tree.appending(name: "file\(index).txt"), replacing: false)
            } catch {
                failures.add(1)
            }
        }
        #expect(failures.value == 0)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && isSound(archive))
        let names = listed(archive)
        #expect(names.filter { $0.hasPrefix("tree/file") }.count == 18 && !names.contains { $0.hasSuffix(".tmp") })
        #expect(
            runTool("/usr/bin/unzip", ["-p", archive.path, "tree/file5.txt"]).output
                == String(repeating: "file 5 ", count: 12_000)
        )
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".tmp") })
    }

    /// A move keeps its source when the archive refuses the file, at the close of the writer or at the rename.
    @Test
    internal func aMoveKeepsItsSourceWhenTheArchiveCannotTakeTheFile() throws {
        let archive = try makeZip()
        try box.file("in/one.txt", "one")
        // The disk is full: the member is refused when its writer closes.
        bench.environment.hasRoom = { _, _ in false }
        let answers = Answers()
        var result = answers.run(
            .move,
            [box.url("in/one.txt")],
            to: TargetSpec(directory: bench.inside(archive, "tree")),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.isEmpty && answers.errors.count == 1 && box.read("in/one.txt") == "one")
        #expect(try !bench.names(bench.inside(archive, "tree")).contains("one.txt"))
        bench.environment.hasRoom = { _, _ in true }

        // The write into the archive fails at the rename (something that is no archive lies in
        // its place): the rename fails with it and is taken back.
        try write("data", to: bench.inside(archive, "tree/.part"))
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        let sound = try Data(contentsOf: archive)
        try Data("no archive".utf8).write(to: archive)
        #expect(throws: ArchiveError.self) { try opened.move("tree/.part", to: "tree/final.txt", replacing: false) }
        #expect(opened.entry("tree/final.txt") == nil && opened.entry("tree/.part") != nil && opened.hasPendingChanges)
        try sound.write(to: archive)
        try opened.move("tree/.part", to: "tree/final.txt", replacing: false)
        #expect(!opened.hasPendingChanges && listed(archive).contains("tree/final.txt") && isSound(archive))
        result = Answers()
            .run(
                .move,
                [box.url("in/one.txt")],
                to: TargetSpec(directory: bench.inside(archive, "tree")),
                fileSystems: bench.fileSystems
            )
        #expect(result.completed.count == 1 && !box.exists("in/one.txt") && listed(archive).contains("tree/one.txt"))
    }

    /// The changed copy of an archive on a server that cannot be sent is sent at the next write.
    @Test
    internal func aFailedUploadIsRepeated() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        try write("late", to: root.appending(name: "late.txt"))
        // The server loses the folder: the changed copy cannot be sent.
        bench.memory.removeTree("/store")
        #expect(bench.store.flushAll(cancellation: nil).count == 1)
        #expect(try bench.store.archive(at: onServer, cancellation: nil).hasPendingChanges)
        _ = bench.memory.addDirectory("/store")
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        let reader = try bench.memory.read(onServer)
        var bytes = Data()
        while let block = try reader.read(upToCount: 1 << 20) { bytes.append(block) }
        try bytes.write(to: box.url("fetched.zip"))
        #expect(isSound(box.url("fetched.zip")) && listed(box.url("fetched.zip")).contains("late.txt"))
    }

    /// New members that cannot be written into their archive are saved in an archive of their own; renames and
    /// deletions
    /// alone leave nothing to save.
    @Test
    internal func membersThatCannotBeWrittenAreSavedInAnArchiveOfTheirOwn() throws {
        let archive = try makeZip()
        try write("only copy", to: bench.inside(archive, "tree/rescued.txt"))
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        // Another program leaves something that is no archive in its place.
        try Data("not a zip".utf8).write(to: archive)
        #expect(bench.store.flushAll(cancellation: nil).count == 1 && opened.hasPendingChanges)
        guard case .saved(let saved) = opened.rescue(quickly: false, before: .distantFuture) else {
            Issue.record("nothing was saved")
            return
        }
        #expect(saved.lastPathComponent == "tree (unsaved changes).zip")
        #expect(runTool("/usr/bin/unzip", ["-p", saved.path, "tree/rescued.txt"]).output == "only copy")
        // Renames and deletions alone leave nothing to save.
        let other = try makeZip("other.zip")
        try bench.zip.remove(bench.inside(other, "tree/empty.txt"))
        guard
            case .nothingToSave = try bench.store.archive(at: other, cancellation: nil)
                .rescue(quickly: false, before: .distantFuture)
        else {
            Issue.record("something was saved")
            return
        }
    }

    /// New members are added to an archive another program changed meanwhile, under a name of their own where the name
    /// was taken; a deletion that cannot be carried over is reported.
    @Test
    internal func newMembersSurviveAChangeFromOutside() throws {
        let archive = try makeZip()
        try write("ours", to: bench.inside(archive, "tree/readme.txt.new"))
        try write("ours too", to: bench.inside(archive, "tree/sub/.hidden2"))
        try bench.zip.remove(bench.inside(archive, "tree/empty.txt"))
        Thread.sleep(forTimeInterval: 0.02)
        try box.file("tree/readme.txt.new", "theirs")
        #expect(runTool("/usr/bin/zip", ["-q", "tree.zip", "tree/readme.txt.new"], in: box.root).status == 0)
        // The deletion cannot be carried over and is reported; the new members are added to
        // the archive as it is now, the one whose name was taken under a name of its own.
        let failures = bench.store.flushAll(cancellation: nil)
        #expect(
            failures.count == 1
                && failures.first?.error.localizedDescription.contains("changed by another program") == true
        )
        #expect(isSound(archive))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt.new"]).output == "theirs")
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt (2).new"]).output == "ours")
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/sub/.hidden2"]).output == "ours too")
        #expect(listed(archive).contains("tree/empty.txt") && bench.store.flushAll(cancellation: nil).isEmpty)
    }
}
