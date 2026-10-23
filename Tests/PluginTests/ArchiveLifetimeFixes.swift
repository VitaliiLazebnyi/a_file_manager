import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// An archive that is being written to is not let go, a reader survives the rewrite of its archive, and the time of an
/// encrypted member can change.
@Suite
internal struct ArchiveLifetimeFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// An archive with an open writer stays in the store, however many others are opened, until its changes are
    /// written.
    @Test
    internal func anArchiveWithAnOpenWriterStaysInTheStore() throws {
        let first = try makeZip("first.zip")
        let opened = try bench.store.archive(at: first, cancellation: nil)
        let writer = try bench.zip.write(bench.inside(first, "tree/slow.txt"))
        try writer.write(Data("slow".utf8))
        // More archives than the store keeps.
        for index in 0..<20 {
            let url = try writeZip("filler\(index).zip") { _ in
                // An archive without members.
            }
            _ = try bench.store.archive(at: url, cancellation: nil)
        }
        #expect(try bench.store.archive(at: first, cancellation: nil) === opened)
        try writer.close(attributes: FileAttributes())
        for index in 0..<20 { _ = try bench.store.archive(at: box.url("filler\(index).zip"), cancellation: nil) }
        #expect(try bench.store.archive(at: first, cancellation: nil) === opened && opened.hasPendingChanges)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && listed(first).contains("tree/slow.txt"))
        // With nothing waiting it goes like any other.
        for index in 0..<20 { _ = try bench.store.archive(at: box.url("filler\(index).zip"), cancellation: nil) }
        #expect(try bench.store.archive(at: first, cancellation: nil) !== opened)
    }

    /// Pending changes keep an archive alive, with no other reference to it, until they are written.
    @Test
    internal func pendingChangesKeepAnArchiveAliveUntilTheyAreWritten() throws {
        let archive = try makeZip()
        bench.environment.flushDelay = 0.05
        // (The urgent timer follows the patient one closely: see `changesAreWrittenShortlyAfterTheLastOne`.)
        bench.environment.escalationDelay = 0.3
        let changed = DispatchSemaphore(value: 0)
        bench.environment.contentsChanged = { _ in changed.signal() }
        // Opened outside the store, and no reference kept beyond the writer's.
        var writer: (any FileWriter)? = try OpenArchive(
            archiveURL: archive,
            localURL: archive,
            fetchedCopy: nil,
            remoteStamp: nil,
            quarantine: nil,
            cancellation: nil,
            environment: bench.environment
        )
        .write("tree/kept.txt", level: nil, password: nil)
        try writer?.write(Data("kept".utf8))
        try writer?.close(attributes: FileAttributes())
        writer = nil
        // (A generous wait: the timer runs at low priority, behind whatever else the machine does.)
        #expect(changed.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(listed(archive).contains("tree/kept.txt") && isSound(archive))
    }

    /// A reader opened before its archive was rewritten reads the same bytes afterwards, and so does an entry looked up
    /// before.
    @Test(arguments: [true, false])
    internal func anOpenReaderSurvivesTheRewriteOfItsArchive(clones: Bool) throws {
        bench.environment.clonesArchives = clones
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let expected = try Data(contentsOf: box.url("tree/readme.txt"))
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        let entry = try #require(opened.entry("tree/readme.txt"))
        let reader = try bench.zip.read(tree.appending(name: "readme.txt"))
        #expect(try reader.read(upToCount: 100)?.count == 100)
        // Members in front of it go, and others arrive: every position in the file changes.
        try bench.zip.remove(tree.appending(name: "big.log"))
        try bench.zip.remove(tree.appending(name: "empty.txt"))
        try write("new", to: tree.appending(name: "new.txt"))
        try bench.store.flush(archive, cancellation: nil)
        try reader.seek(to: 0)
        var data = Data()
        while let block = try reader.read(upToCount: 5_000) { data.append(block) }
        reader.close()
        #expect(data == expected)
        // The entry looked up before the rewrite reads the same bytes, and so does a new one.
        let stream = try opened.open(entry, slot: nil)
        #expect(try stream.readFully(1 << 20) == expected)
        #expect(try bench.read(tree.appending(name: "readme.txt")) == expected && isSound(archive))
    }

    /// Changing the time of a member with the old encryption, whose check byte is the time, keeps it readable here and
    /// for unzip.
    @Test
    internal func changingTheTimeOfAnEncryptedMemberKeepsItReadable() throws {
        let tree = try bench.makeTree()
        let archive = box.url("secret.zip")
        // The old encryption, whose check byte is the time; `unzip` reads no other.
        try bench.pack([tree.appendingPathComponent("readme.txt")], to: archive) { options in
            options.password = "sesame"
            options.encryption = .legacy
        }
        let member = bench.inside(archive, "readme.txt")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try bench.zip.setAttributes(FileAttributes(modified: stamp), of: member)
        try bench.store.flush(archive, cancellation: nil)
        bench.store.close()
        bench.passwords.set(["sesame"])
        #expect(try bench.item(member).modified == stamp)
        #expect(try bench.read(member) == Data(contentsOf: tree.appendingPathComponent("readme.txt")))
        let check = runTool("/usr/bin/unzip", ["-P", "sesame", "-tq", archive.path])
        #expect(check.status == 0, "\(check.output)")
    }
}
