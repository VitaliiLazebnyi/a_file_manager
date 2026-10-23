import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Changes are appended to a ZIP instead of rewriting it, as long as the unused stretches stay small.
@Suite
internal struct ArchiveAppendFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Adding, renaming and dating members append to the archive and leave the old members where they are; a deletion
    /// writes it anew.
    @Test
    internal func addingRenamingAndDatingLeaveTheOldMembersWhereTheyAre() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let original = try Data(contentsOf: archive)
        let old = try ZipDirectory.read(RandomAccessFile(archive, shownAs: nil), maxEntries: .max, check: nil)
        let before = try memberOffsets(of: archive)
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)

        try write("appended", to: tree.appending(name: "added.txt"))
        try bench.zip.createDirectory(at: tree.appending(name: "folder"))
        try bench.zip.setAttributes(
            FileAttributes(modified: stamp, permissions: 0o600),
            of: tree.appending(name: "readme.txt")
        )
        try bench.zip.move(tree.appending(name: "empty.txt"), to: tree.appending(name: "void.txt"), replacing: false)
        try bench.store.flush(archive, cancellation: nil)

        // The members' data was not written again: the file starts as it did, but for the
        // four bytes of the time that was changed.
        let patched = Int(try #require(before["tree/readme.txt"])) + 10
        let now = try withTheOldTime(Data(contentsOf: archive), from: original, at: patched)
        let after = try memberOffsets(of: archive)
        #expect(now.prefix(Int(old.directoryOffset)) == original.prefix(Int(old.directoryOffset)))
        for (name, offset) in before where name != "tree/empty.txt" { #expect(after[name] == offset, "\(name)") }
        #expect(
            try #require(after["tree/added.txt"]) >= old.directoryOffset
                && #require(after["tree/void.txt"]) >= old.directoryOffset
        )
        #expect(after["tree/empty.txt"] == nil && after["tree/folder/"] != nil)

        try expectUnzipUnpacksTheChanges(of: archive, stamp: stamp)
        bench.store.close()
        #expect(try bench.names(tree) == ["added.txt", "big.log", "folder", "hollow", "readme.txt", "sub", "void.txt"])
        #expect(try bench.item(tree.appending(name: "readme.txt")).modified == stamp)

        // A deletion writes the archive anew, and with that the stretch the rename left is gone.
        let grown = try Data(contentsOf: archive).count
        try bench.zip.remove(tree.appending(name: "big.log"))
        try bench.store.flush(archive, cancellation: nil)
        #expect(try Data(contentsOf: archive).count < grown / 2 && isSound(archive))
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".tmp") })
    }

    /// Where the local header of each member of `archive` starts, by name.
    private func memberOffsets(of archive: URL) throws -> [String: UInt64] {
        var found: [String: UInt64] = [:]
        for record in try ZipDirectory.read(RandomAccessFile(archive, shownAs: nil), maxEntries: .max, check: nil)
            .records
        {
            if case .archive(let offset, _) = record.source { found[record.name] = offset }
        }
        return found
    }

    /// `changed`, longer than `original`, with the two places of the member time that was changed (the DOS time
    /// in the header at `patched`, and the time field behind it) set back to the bytes of `original`.
    private func withTheOldTime(_ changed: Data, from original: Data, at patched: Int) throws -> Data {
        var now = changed
        #expect(now.count > original.count)
        now.replaceSubrange(patched..<patched + 4, with: original[patched..<patched + 4])
        let stampAt = try #require(now.range(of: Data([0x55, 0x54]), in: patched..<patched + 200))
        now.replaceSubrange(
            stampAt.lowerBound + 5..<stampAt.lowerBound + 9,
            with: original[stampAt.lowerBound + 5..<stampAt.lowerBound + 9]
        )
        return now
    }

    /// Expects the system's unzip to find `archive` sound and to unpack the changes of the test: the new time and
    /// permissions of the readme, the added file, the renamed one and the new folder.
    private func expectUnzipUnpacksTheChanges(of archive: URL, stamp: Date) throws {
        let check = runTool("/usr/bin/unzip", ["-tq", archive.path])
        #expect(check.status == 0, "\(check.output)")
        try box.folder("unzipped")
        #expect(runTool("/usr/bin/unzip", ["-q", archive.path, "-d", box.url("unzipped").path]).status == 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("unzipped/tree/readme.txt").path)
        #expect(attributes[.modificationDate] as? Date == stamp && attributes[.posixPermissions] as? Int == 0o600)
        #expect(
            box.read("unzipped/tree/added.txt") == "appended" && box.exists("unzipped/tree/void.txt")
                && box.exists("unzipped/tree/folder")
        )
    }

    /// Many renames of a large member end in one rewrite instead of an archive full of unused stretches.
    @Test
    internal func manyRenamesEndInOneRewriteInsteadOfAnArchiveFullOfHoles() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let size = try Data(contentsOf: archive).count
        // Renaming the largest member again and again appends it each time, until the unused
        // stretches would be a quarter of the file.
        var name = "big.log"
        for round in 0..<6 {
            try bench.zip.move(
                tree.appending(name: name),
                to: tree.appending(name: "big\(round).log"),
                replacing: false
            )
            name = "big\(round).log"
            try bench.store.flush(archive, cancellation: nil)
            #expect(isSound(archive))
        }
        #expect(try Data(contentsOf: archive).count < size * 2)
        #expect(try bench.read(tree.appending(name: name)) == Data(contentsOf: box.url("tree/big.log")))
    }

    /// A self-extracting archive keeps its program in front when it is changed, and its offsets then count from the
    /// start of the file.
    @Test(arguments: [true, false])
    internal func aSelfExtractingArchiveKeepsItsProgram(clones: Bool) throws {
        bench.environment.clonesArchives = clones
        let plain = try makeZip("plain.zip")
        let stub =
            Data("#!/bin/sh\necho this would unpack what follows\nexit 0\n".utf8) + Data(repeating: 0x90, count: 5_000)
        let archive = box.url("sfx.zip")
        try (stub + Data(contentsOf: plain)).write(to: archive)
        let tree = bench.inside(archive, "tree")
        #expect(try bench.names(tree).count == 5)
        try write("added", to: tree.appending(name: "added.txt"))
        try bench.store.flush(archive, cancellation: nil)
        #expect(try Data(contentsOf: archive).prefix(stub.count) == stub)
        try bench.zip.remove(tree.appending(name: "big.log"))
        try bench.store.flush(archive, cancellation: nil)
        #expect(try Data(contentsOf: archive).prefix(stub.count) == stub)
        bench.store.close()
        #expect(try bench.names(tree) == ["added.txt", "empty.txt", "hollow", "readme.txt", "sub"])
        #expect(try bench.read(tree.appending(name: "readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
        // The offsets now count from the start of the file, which is what unzip expects.
        let check = runTool("/usr/bin/unzip", ["-tq", archive.path])
        #expect(check.status == 0, "\(check.output)")
    }
}
