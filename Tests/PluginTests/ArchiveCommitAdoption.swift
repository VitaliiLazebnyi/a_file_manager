import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The kernel's commit, as the archives adopt it: what waits is written when it is asked for, also where the archive
/// lies inside another or on a server.
@Suite
internal struct ArchiveCommitAdoption: ArchiveFixSuite {
    /// The failure a server gives when it cannot make a file durable.
    private struct Refused: Error {}

    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A commit puts what closed writers, renames, deletions and new folders brought into the archive file; with
    /// nothing to write it does nothing.
    @Test
    internal func aCommitPutsWhatClosedWritersBroughtIntoTheArchiveFile() throws {
        // Nothing is written at a rename: what is kept back is up to the delay or to the commit.
        bench.environment.immediateWriteLimit = 0
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try write(String(repeating: "new file ", count: 100_000), to: tree.appending(name: ".afm-1.tmp"))
        try bench.zip.move(tree.appending(name: ".afm-1.tmp"), to: tree.appending(name: "new.txt"), replacing: false)
        try bench.zip.remove(tree.appending(name: "empty.txt"))
        try bench.zip.setAttributes(FileAttributes(permissions: 0o600), of: tree.appending(name: "readme.txt"))
        try bench.zip.createDirectory(at: tree.appending(name: "made"))
        #expect(!listed(archive).contains("tree/new.txt") && listed(archive).contains("tree/empty.txt"))

        try bench.zip.commit(tree.appending(name: "anything"), cancellation: CancellationFlag())
        #expect(isSound(archive))
        #expect(try !bench.store.archive(at: archive, cancellation: nil).hasPendingChanges)
        let names = listed(archive)
        #expect(names.contains("tree/new.txt") && names.contains("tree/made/") && !names.contains("tree/empty.txt"))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/new.txt"]).output.count == 900_000)
        #expect(runTool("/usr/bin/zipinfo", [archive.path, "tree/readme.txt"]).output.contains("-rw-------"))
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".tmp") })
        // Again with nothing to write: nothing happens.
        let before = FileSignature.of(archive.path)
        try bench.zip.commit(tree, cancellation: CancellationFlag())
        #expect(FileSignature.of(archive.path) == before)
    }

    /// An archive on a drive is written and let go of before the drive is ejected, and not let go of while changes
    /// wait.
    @Test
    internal func anArchiveOnADriveIsWrittenAndLetGoOfBeforeTheDriveIsEjected() throws {
        bench.environment.immediateWriteLimit = 0
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try bench.zip.createDirectory(at: tree.appending(name: "made"))
        // Something else on the drive, or another drive, is no reason to let go.
        bench.store.release(on: box.url("elsewhere"))
        #expect(bench.store.openArchive(at: archive) != nil)
        // An archive with changes still to write stays: going now would lose them.
        bench.store.release(on: box.root)
        #expect(bench.store.openArchive(at: archive) != nil && !listed(archive).contains("tree/made/"))
        // As the eject does it: written first, then let go of.
        try bench.store.bringUpToDate(box.root, cancellation: CancellationFlag())
        bench.store.release(on: box.root)
        #expect(
            bench.store.openArchive(at: archive) == nil && listed(archive).contains("tree/made/") && isSound(archive)
        )
    }

    /// A commit that fails leaves the archive untouched and keeps every change for the next commit.
    @Test
    internal func aFailedCommitKeepsEverythingForTheNextTry() throws {
        bench.environment.immediateWriteLimit = 0
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try write("precious", to: tree.appending(name: "new.txt"))
        try bench.zip.remove(tree.appending(name: "empty.txt"))
        // The folder cannot be written to: no new file can be put next to the archive.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path) }
        let before = FileSignature.of(archive.path)
        for _ in 0..<2 {
            #expect(throws: (any Error).self) { try bench.zip.commit(tree, cancellation: CancellationFlag()) }
            #expect(FileSignature.of(archive.path) == before && isSound(archive))
            #expect(try bench.store.archive(at: archive, cancellation: nil).hasPendingChanges)
            #expect(try bench.read(tree.appending(name: "new.txt")) == Data("precious".utf8))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path)
        try bench.zip.commit(tree, cancellation: CancellationFlag())
        #expect(
            isSound(archive) && listed(archive).contains("tree/new.txt") && !listed(archive).contains("tree/empty.txt")
        )
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/new.txt"]).output == "precious")
    }

    /// A commit of an archive inside another reaches the outer archive on the disk.
    @Test
    internal func aCommitReachesTheArchivesThatHoldTheArchive() throws {
        let tree = try bench.makeTree()
        try bench.pack([tree], to: box.url("inner.zip"))
        try bench.pack([box.url("inner.zip")], to: box.url("outer.zip"))
        bench.environment.immediateWriteLimit = 0
        let inner = ArchiveURL.make(
            scheme: "zip",
            archive: bench.inside(box.url("outer.zip"), "inner.zip"),
            innerPath: ""
        )
        #expect(bench.zip.capabilities(for: inner) == [.write, .deferredWrites])
        try write("deep", to: inner.appending(name: "tree").appending(name: "added.txt"))
        try bench.zip.commit(inner, cancellation: CancellationFlag())
        // Without anything else asking: the outer archive on the disk holds the changed inner one.
        #expect(runTool("/usr/bin/unzip", ["-q", "outer.zip", "-d", "x"], in: box.root).status == 0)
        #expect(listed(box.url("x/inner.zip")).contains("tree/added.txt") && isSound(box.url("outer.zip")))
    }

    /// An archive on a server is uploaded and committed there at a commit, which fails when the server's commit fails.
    @Test
    internal func anArchiveOnAServerIsCommittedThereToo() throws {
        let tree = try bench.makeTree()
        bench.memory.capabilitiesAt = { _ in [.write, .deferredWrites] }
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        try write("late", to: root.appending(name: "late.txt"))
        #expect(bench.memory.commits.isEmpty)
        try bench.zip.commit(root, cancellation: CancellationFlag())
        // Uploaded, and then the server was told to make it durable.
        #expect(bench.memory.commits == ["/store/tree.zip"])
        #expect(try !bench.store.archive(at: onServer, cancellation: nil).hasPendingChanges)
        let reader = try bench.memory.read(onServer)
        var bytes = Data()
        while let block = try reader.read(upToCount: 1 << 20) { bytes.append(block) }
        try bytes.write(to: box.url("fetched.zip"))
        #expect(listed(box.url("fetched.zip")).contains("late.txt"))
        // A server that cannot make it durable fails the commit.
        bench.memory.commitFailure = Refused()
        #expect(throws: (any Error).self) { try bench.zip.commit(root, cancellation: CancellationFlag()) }
    }

    /// Many small files renamed into an archive do not write the archive for each of them.
    @Test
    internal func manySmallFilesDoNotWriteTheArchiveForEachOfThem() throws {
        bench.environment.immediateWriteLimit = 16 << 10
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        var files: Set<UInt64> = []
        for index in 0..<200 {
            let temporary = tree.appending(name: ".afm-\(index).tmp")
            try write("small file \(index)", to: temporary)
            try bench.zip.move(temporary, to: tree.appending(name: "small\(index).txt"), replacing: false)
            files.insert(FileSignature.of(archive.path)?.inode ?? 0)
        }
        // A new archive file stands for a write. The cost of writes at a rename is held to what
        // the files bring in (and a little), where it was 200 writes.
        #expect(files.count < 25, "\(files.count) writes")
        try bench.zip.commit(tree, cancellation: CancellationFlag())
        #expect(isSound(archive))
        let names = Set(listed(archive))
        #expect((0..<200).allSatisfy { names.contains("tree/small\($0).txt") })
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/small199.txt"]).output == "small file 199")
    }

    /// Packing with the sources deleted deletes them only once the archive is committed where it lies.
    @Test
    internal func packAndDeleteSourcesWaitsForTheArchiveWhereItLies() throws {
        // The new archive lies inside another one, which keeps it back.
        let outer = try makeZip("outer.zip")
        bench.environment.immediateWriteLimit = 0
        try box.file("src/a.txt", "alpha")
        try box.file("src/b.txt", "beta")
        let result = try bench.pack(
            [box.url("src/a.txt"), box.url("src/b.txt")],
            to: bench.inside(outer, "tree/packed.tar")
        ) { options in
            options.format = .tar
            options.movesSources = true
        }
        #expect(result.completed.count == 2 && !box.exists("src/a.txt") && !box.exists("src/b.txt"))
        #expect(listed(outer).contains("tree/packed.tar") && isSound(outer))

        // On a server whose commit fails the sources stay and the pack fails.
        bench.memory.capabilitiesAt = { _ in [.write, .deferredWrites] }
        bench.memory.commitFailure = Refused()
        try box.file("src/c.txt", "gamma")
        var options = PackOptions()
        options.format = .tar
        options.movesSources = true
        let packer = Packer(
            fileSystems: bench.fileSystems,
            store: bench.store,
            monitor: bench.monitor,
            options: options
        )
        let failed = packer.run(
            [try bench.item(box.url("src/c.txt"))],
            archive: bench.memory.url("/store/c.tar"),
            innerFolder: ""
        )
        #expect(failed.failure != nil && failed.completed.isEmpty && box.exists("src/c.txt"))
        #expect(bench.memory.commits == ["/store/c.tar"])
    }

    /// The packed items are deselected by the names the panel shows them with, paths included.
    @Test
    internal func thePackedOperandsAreDeselectedByTheNamesThePanelMarksThemWith() {
        // A branch or list view names its items by path.
        let notes = FileItem(url: URL(fileURLWithPath: "/A/notes.txt"), name: "sub/notes.txt")
        let todo = FileItem(url: URL(fileURLWithPath: "/A/todo.txt"), name: "other/todo.txt")
        let left = FileItem(url: URL(fileURLWithPath: "/A/left.txt"), name: "left.txt")
        #expect(
            ArchiveCommands.names(of: [notes, todo, left], packedAs: [notes.url, todo.url]) == [
                "sub/notes.txt", "other/todo.txt"
            ]
        )
    }
}
