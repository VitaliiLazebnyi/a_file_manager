import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Changes to a ZIP through its file system: in place, kept back, refused, and from outside.
@Suite
internal struct ArchivesZipChangeTests {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench
    /// The sandbox the archives and trees are made in.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Folders and files made, renamed, copied, deleted and changed in a ZIP show at once and are written in place.
    @Test
    internal func aZipIsChangedInPlace() throws {
        let archive = try bench.zipOfTree("tree.zip")
        let root = bench.inside(archive, "", scheme: ArchiveURL.writableScheme)
        let tree = root.appending(name: "tree")
        let before = FileSignature.of(archive.path)
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)

        try change(tree, stamp: stamp)

        // Everything is visible at once, before the archive file is touched.
        #expect(FileSignature.of(archive.path) == before && bench.store.flushAll(cancellation: nil).isEmpty == true)
        #expect(FileSignature.of(archive.path) != before)
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".tmp") })
        for _ in 0..<2 {
            try expectChanged(tree, stamp: stamp)
            // The second round reads the archive afresh, as after a restart.
            bench.store.close()
        }
        try expectUnzipAgrees(with: archive, stamp: stamp)
    }

    /// A folder that exists only through its files stays when its last file goes; an emptied ZIP stays a ZIP.
    @Test
    internal func deletingTheLastFileKeepsItsFolder() throws {
        // The system's zip -D writes no entries for folders: they exist only through their files.
        try box.file("tree/a/b/only.txt", "only")
        #expect(runTool("/usr/bin/zip", ["-qrD", "bare.zip", "tree"], in: box.root).status == 0)
        let folder = bench.inside(box.url("bare.zip"), "tree/a/b", scheme: ArchiveURL.writableScheme)
        #expect(
            try bench.names(
                bench.inside(box.url("bare.zip"), "tree/a", scheme: ArchiveURL.writableScheme),
                showHidden: true
            ) == ["b"]
        )
        try bench.zip.remove(folder.appending(name: "only.txt"))
        #expect(try bench.names(folder, showHidden: true).isEmpty)
        try bench.store.flush(box.url("bare.zip"), cancellation: nil)
        bench.store.close()
        #expect(try bench.names(folder, showHidden: true).isEmpty && bench.item(folder).isDirectory)
        try bench.zip.remove(folder)
        try bench.zip.remove(folder.deletingLastPathComponent())
        try bench.zip.remove(bench.inside(box.url("bare.zip"), "tree", scheme: ArchiveURL.writableScheme))
        try bench.store.flush(box.url("bare.zip"), cancellation: nil)
        // An archive without members is still an archive.
        #expect(
            try bench.names(bench.inside(box.url("bare.zip"), "", scheme: ArchiveURL.writableScheme), showHidden: true)
                .isEmpty
        )
        #expect(try Data(contentsOf: box.url("bare.zip")).count == 22)
    }

    /// Read-only formats, copies between archives and a ZIP that may not be written refuse changes at once.
    @Test
    internal func otherFormatsAndProtectedFilesRefuseChanges() throws {
        let tree = try bench.makeTree("tree")
        try bench.pack([tree], to: box.url("tree.tar"), innerFolder: "") { $0.format = .tar }
        let inTar = bench.inside(box.url("tree.tar"), "tree", scheme: ArchiveURL.readOnlyScheme)
        #expect(throws: ArchiveError.self) { try bench.readOnly.createDirectory(at: inTar.appending(name: "new")) }
        #expect(throws: ArchiveError.self) { try bench.readOnly.remove(inTar.appending(name: "empty.txt")) }
        #expect(throws: ArchiveError.self) { _ = try bench.readOnly.write(inTar.appending(name: "x.txt")) }
        #expect(throws: FileSystemError.self) { try bench.readOnly.trash(inTar.appending(name: "empty.txt")) }
        // Between two archives the caller has to stream.
        let archive = try bench.zipOfTree("tree.zip")
        #expect(throws: FileSystemError.self) {
            try bench.zip.copy(
                bench.inside(archive, "tree/empty.txt", scheme: ArchiveURL.writableScheme),
                to: bench.inside(box.url("other.zip"), "x", scheme: ArchiveURL.writableScheme)
            ) { _ in true }
        }
        // A ZIP that may not be written to says so at the first change, not when it is too late.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: archive.path)
        #expect(throws: (any Error).self) {
            try bench.zip.remove(bench.inside(archive, "tree/empty.txt", scheme: ArchiveURL.writableScheme))
        }
        #expect(
            try bench.names(bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme), showHidden: true)
                .contains("empty.txt")
        )
    }

    /// An archive replaced by another program is read afresh; waiting changes to its old members are given up.
    @Test
    internal func aChangeFromOutsideIsNoticed() throws {
        let archive = try bench.zipOfTree("tree.zip")
        let root = bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme)
        #expect(try bench.names(root, showHidden: true).count == 5)
        // Another program replaces the archive: the next question is answered from the new one.
        try FileManager.default.removeItem(at: archive)
        try box.file("other/solo.txt", "solo")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "other"], in: box.root).status == 0)
        #expect(bench.fileSystems.item(at: root) == nil)
        #expect(
            try bench.names(bench.inside(archive, "other", scheme: ArchiveURL.writableScheme), showHidden: true) == [
                "solo.txt"
            ]
        )

        // Changes waiting here are not written over an archive that was changed meanwhile:
        // what was done to its old members is given up and reported, and a new member is
        // added to the archive as it is now.
        try bench.writeText(
            "pending",
            to: bench.inside(archive, "other/pending.txt", scheme: ArchiveURL.writableScheme),
            modified: nil
        )
        try bench.zip.move(
            bench.inside(archive, "other/solo.txt", scheme: ArchiveURL.writableScheme),
            to: bench.inside(archive, "other/renamed.txt", scheme: ArchiveURL.writableScheme),
            replacing: false
        )
        Thread.sleep(forTimeInterval: 0.02)
        #expect(runTool("/usr/bin/zip", ["-q", "tree.zip", "tree/empty.txt"], in: box.root).status == 0)
        let failures = bench.store.flushAll(cancellation: nil)
        #expect(
            failures.count == 1
                && failures.first?.error.localizedDescription.contains("changed by another program") == true
        )
        #expect(
            try bench.names(bench.inside(archive, "", scheme: ArchiveURL.writableScheme), showHidden: true) == [
                "other", "tree"
            ]
        )
        #expect(
            try bench.names(bench.inside(archive, "other", scheme: ArchiveURL.writableScheme), showHidden: true) == [
                "pending.txt", "solo.txt"
            ]
        )
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path], in: nil).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "other/pending.txt"], in: nil).output == "pending")
    }

    /// Changes are written shortly after the last one, but not while a member is still being written.
    @Test
    internal func changesAreWrittenShortlyAfterTheLastOne() throws {
        let archive = try bench.zipOfTree("tree.zip")
        bench.environment.flushDelay = 0.15
        // The write is due at low priority; on a machine where that does not get to run
        // (every core busy with other tests), the urgent timer behind it does the work.
        bench.environment.escalationDelay = 0.3
        let changed = DispatchSemaphore(value: 0)
        bench.environment.contentsChanged = { _ in changed.signal() }
        let before = FileSignature.of(archive.path)
        // A member that is still being written holds the flush back.
        let writer = try bench.zip.write(bench.inside(archive, "tree/slow.txt", scheme: ArchiveURL.writableScheme))
        try bench.zip.remove(bench.inside(archive, "tree/empty.txt", scheme: ArchiveURL.writableScheme))
        try writer.write(Data("slow".utf8))
        #expect(changed.wait(timeout: .now() + 0.5) == .timedOut && FileSignature.of(archive.path) == before)
        try writer.close(attributes: FileAttributes())
        // (A generous wait: the timer runs at low priority, behind whatever else the machine does.)
        #expect(changed.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(FileSignature.of(archive.path) != before)
        let listed = runTool("/usr/bin/unzip", ["-Z1", archive.path], in: nil).output
        #expect(listed.contains("tree/slow.txt") && !listed.contains("empty.txt"))
    }

    /// Makes, renames, copies, deletes and changes members of the standard tree in a ZIP.
    private func change(_ tree: URL, stamp: Date) throws {
        // New folder, with the folders above it.
        try bench.zip.createDirectory(at: tree.appending(name: "new").appending(name: "nested"))
        try bench.zip.createDirectory(at: tree.appending(name: "sub"))
        // New files; a taken name is refused.
        try bench.writeText(
            "fresh contents",
            to: tree.appending(name: "new").appending(name: "fresh.txt"),
            modified: stamp
        )
        try bench.writeText("", to: tree.appending(name: "new").appending(name: "nothing"), modified: nil)
        #expect(throws: FileSystemError.self) {
            try bench.writeText("x", to: tree.appending(name: "readme.txt"), modified: nil)
        }
        // Rename a file and a folder with everything in it.
        try bench.zip.move(
            tree.appending(name: "readme.txt"),
            to: tree.appending(name: "LIESMICH.txt"),
            replacing: false
        )
        try bench.zip.move(tree.appending(name: "sub"), to: tree.appending(name: "unter"), replacing: false)
        #expect(throws: FileSystemError.self) {
            try bench.zip.move(
                tree.appending(name: "big.log"),
                to: tree.appending(name: "empty.txt"),
                replacing: false
            )
        }
        try bench.zip.move(tree.appending(name: "big.log"), to: tree.appending(name: "empty.txt"), replacing: true)
        // A copy inside the archive shares the compressed data.
        try bench.zip.copy(tree.appending(name: "LIESMICH.txt"), to: tree.appending(name: "copy.txt")) { _ in true }
        // Delete: a file, an empty folder; a folder with contents is refused.
        try bench.zip.remove(tree.appending(name: "unter").appending(name: "random.bin"))
        try bench.zip.remove(tree.appending(name: "hollow"))
        #expect(throws: (any Error).self) { try bench.zip.remove(tree.appending(name: "unter")) }
        try bench.zip.setAttributes(
            FileAttributes(modified: stamp, permissions: 0o700),
            of: tree.appending(name: "copy.txt")
        )
    }

    /// Checks the members `change` left, as the archive's file system shows them.
    private func expectChanged(_ tree: URL, stamp: Date) throws {
        #expect(
            try bench.names(tree, showHidden: true) == ["LIESMICH.txt", "copy.txt", "empty.txt", "new", "unter"]
        )
        #expect(try bench.names(tree.appending(name: "unter"), showHidden: true) == [".hidden", "deep"])
        #expect(
            try bench.names(tree.appending(name: "new"), showHidden: true) == ["fresh.txt", "nested", "nothing"]
        )
        let fresh = try bench.item(tree.appending(name: "new").appending(name: "fresh.txt"))
        #expect(fresh.size == 14 && fresh.modified == stamp && fresh.permissions == 0o600)
        #expect(try bench.read(fresh.url) == Data("fresh contents".utf8))
        #expect(try bench.read(tree.appending(name: "empty.txt")) == Data(contentsOf: box.url("tree/big.log")))
        #expect(try bench.read(tree.appending(name: "copy.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
        #expect(try bench.item(tree.appending(name: "copy.txt")).permissions == 0o700)
        #expect(
            try bench.read(
                tree.appending(name: "unter").appending(name: "deep").appending(name: "übung – ñ 日本.txt")
            )
                == Data("unicode name".utf8)
        )
    }

    /// Checks that the system's unzip agrees with every byte of the changed archive.
    private func expectUnzipAgrees(with archive: URL, stamp: Date) throws {
        let check = runTool("/usr/bin/unzip", ["-tq", archive.path], in: nil)
        #expect(check.status == 0, "\(check.output)")
        try box.folder("unzipped")
        #expect(runTool("/usr/bin/unzip", ["-q", archive.path, "-d", box.url("unzipped").path], in: nil).status == 0)
        let unzipped = snapshot(box.url("unzipped/tree"))
        #expect(
            unzipped.keys.sorted() == [
                "LIESMICH.txt", "copy.txt", "empty.txt", "new/fresh.txt", "new/nested", "new/nothing", "unter/.hidden",
                "unter/deep/übung – ñ 日本.txt"
            ]
        )
        #expect(unzipped["new/fresh.txt"] == Data("fresh contents".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("unzipped/tree/new/fresh.txt").path)
        #expect(attributes[.modificationDate] as? Date == stamp && attributes[.posixPermissions] as? Int == 0o600)
    }
}
