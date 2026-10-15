import AFMKernel
import Foundation
import os
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Changing a ZIP in memory: folders, writers, renames, copies and attributes, and what each
/// of them refuses.
@Suite
internal struct CoverageArchivesChangeTests {
    private let bench: ArchiveBench
    private let clock = CoverageArchivesClock()
    private var box: Sandbox { bench.box }

    /// A bench whose delayed writes are scheduled on a clock the test turns.
    internal init() throws {
        bench = try ArchiveBench()
        bench.environment.schedule = { [clock] in clock.schedule($0, $1, $2) }
    }

    /// A ZIP with a file and a folder holding a file, opened.
    private func archive(_ options: [String] = []) throws -> OpenArchive {
        let url = try CoverageArchives.zip(
            "changes.zip", in: box, ["file.txt": "file", "folder/inner.txt": "inner"], options: options)
        return try bench.store.archive(at: url)
    }

    private func add(_ path: String, _ text: String, to archive: OpenArchive) throws {
        let writer = try archive.write(path)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    private func read(_ archive: OpenArchive, _ path: String) throws -> String {
        let stream = try archive.open(try #require(archive.entry(path)))
        defer { stream.close() }
        return String(decoding: try stream.readFully(1 << 20), as: UTF8.self)
    }

    /// Checks that the paths a change names are checked: a folder below a file, a member
    /// without a name or below a file, a rename to nowhere, into itself or onto a full folder.
    @Test
    internal func changesThatCannotBeMadeAreRefused() throws {
        let archive = try archive()
        #expect(throws: ArchiveError.self) { try archive.makeDirectory("file.txt/sub") }
        #expect(throws: ArchiveError.self) { _ = try archive.write("") }
        #expect(throws: ArchiveError.self) { _ = try archive.write("file.txt/below.txt") }
        #expect(throws: ArchiveError.self) { try archive.move("file.txt", to: "", replacing: false) }
        #expect(throws: ArchiveError.self) { try archive.move("missing.txt", to: "other.txt", replacing: false) }
        #expect(throws: FileSystemError.self) { try archive.move("folder", to: "folder/deeper", replacing: false) }
        try archive.makeDirectory("full")
        try add("full/kept.txt", "kept", to: archive)
        #expect(throws: FileSystemError.self) { try archive.move("folder", to: "full", replacing: true) }
        #expect(throws: ArchiveError.self) { _ = try archive.duplicate("folder", to: "copy") }
        #expect(throws: ArchiveError.self) { _ = try archive.duplicate("missing.txt", to: "copy") }
        #expect(throws: FileSystemError.self) { _ = try archive.duplicate("file.txt", to: "folder/inner.txt") }
        #expect(throws: ArchiveError.self) { try archive.setAttributes(FileAttributes(), of: "missing.txt") }
        // A rename onto itself changes nothing.
        let changes = archive.hasPendingChanges
        try archive.move("file.txt", to: "file.txt", replacing: false)
        #expect(archive.hasPendingChanges == changes && archive.entry("file.txt") != nil)
    }

    /// Checks that a member may be written into folders that do not exist yet.
    @Test
    internal func aMemberBringsTheFoldersAboveIt() throws {
        let archive = try archive()
        try add("new/deep/member.txt", "deep", to: archive)
        #expect(try read(archive, "new/deep/member.txt") == "deep" && archive.entry("new/deep")?.isDirectory == true)
    }

    /// Checks that of two writers of one name, the one that finishes last wins.
    @Test
    internal func ofTwoWritersOfOneNameTheLastToFinishWins() throws {
        let archive = try archive()
        let first = try archive.write("twice.txt")
        let second = try archive.write("twice.txt")
        try second.write(Data("second".utf8))
        try second.close(attributes: FileAttributes())
        try first.write(Data("first".utf8))
        try first.close(attributes: FileAttributes())
        #expect(try read(archive, "twice.txt") == "first")
        #expect(bench.store.flushAll().isEmpty && CoverageArchives.listed(box.url("changes.zip")).contains("twice.txt"))
    }

    /// Checks that a writer that cannot make its temporary file fails at once and leaves the archive idle.
    @Test
    internal func aWriterWithoutATemporaryFileFailsAtOnce() throws {
        let archive = try archive()
        let scratch = try bench.environment.scratch.newFile("probe").deletingLastPathComponent()
        #expect(chmod(scratch.path, 0o500) == 0)
        defer { chmod(scratch.path, 0o700) }
        #expect(throws: (any Error).self) { _ = try archive.write("refused.txt") }
        #expect(!archive.isBusy && archive.entry("refused.txt") == nil)
    }

    /// Checks that a writer that is given up, or that finds no room, arms the delayed write
    /// for the changes that wait.
    @Test
    internal func writersThatEndWithoutAMemberLeaveTheWaitingChangesToTheTimer() throws {
        bench.environment.flushDelay = 1
        let archive = try archive()
        try archive.remove("file.txt")
        let due = clock.take()
        #expect(due.count == 2)
        var abandoned: (any FileWriter)? = try archive.write("abandoned.txt")
        try abandoned?.write(Data("half".utf8))
        abandoned = nil
        #expect(archive.isBusy && archive.entry("abandoned.txt") == nil)
        let crowded = try archive.write("crowded.txt")
        try crowded.write(Data("data".utf8))
        bench.environment.hasRoom = { _, _ in false }
        #expect(throws: ArchiveError.self) { try crowded.close(attributes: FileAttributes()) }
        bench.environment.hasRoom = { _, _ in true }
        #expect(archive.entry("crowded.txt") == nil && archive.hasPendingChanges)
        bench.environment.flushDelay = 0
        due.first?.work()
        #expect(CoverageArchives.listed(box.url("changes.zip")) == ["folder/inner.txt"])
    }

    /// Checks that a writer stops taking data when the disk runs out of room.
    @Test
    internal func aWriterStopsWhenTheRoomRunsOut() throws {
        let archive = try archive()
        let room = OSAllocatedUnfairLock(initialState: true)
        bench.environment.hasRoom = { _, _ in room.withLock { $0 } }
        let writer = try archive.write("growing.txt")
        try writer.write(Data("fits".utf8))
        room.withLock { $0 = false }
        // The room is looked at every 32 MB.
        #expect(throws: ArchiveError.self) { try writer.write(Data(count: 33 << 20)) }
    }

    /// Checks copies inside the archive: of a member that is in the file and of one that is not yet.
    @Test
    internal func copiesShareTheDataOfMembersOldAndNew() throws {
        let archive = try archive()
        try add("fresh.txt", "fresh", to: archive)
        #expect(try archive.duplicate("fresh.txt", to: "fresh copy.txt") == 5)
        #expect(try archive.duplicate("file.txt", to: "file copy.txt") == 4)
        #expect(bench.store.flushAll().isEmpty)
        #expect(CoverageArchives.contents(of: "fresh copy.txt", in: box.url("changes.zip")) == "fresh")
        #expect(CoverageArchives.contents(of: "file copy.txt", in: box.url("changes.zip")) == "file")
    }

    /// Checks that a folder the archive has no entry for gets one when its attributes change,
    /// and is renamed with what is in it.
    @Test
    internal func foldersWithoutAnEntryOfTheirOwnCanBeChanged() throws {
        let archive = try archive(["-D"])
        #expect(archive.entry("folder")?.isImplicit == true)
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        try archive.setAttributes(FileAttributes(modified: stamp, permissions: 0o700), of: "folder")
        #expect(archive.entry("folder")?.isImplicit == false && archive.entry("folder")?.modified == stamp)
        let plain = try CoverageArchives.zip("plain.zip", in: box, ["a/b/c.txt": "c"], options: ["-D"])
        let other = try bench.store.archive(at: plain)
        try other.move("a", to: "z", replacing: false)
        #expect(try read(other, "z/b/c.txt") == "c" && other.entry("a") == nil)
    }

    /// Checks that after a rename that wrote at once, and after a commit, the timer tells the
    /// panels that the archive file changed.
    @Test
    internal func writesAtOnceTellThePanelsLater() throws {
        bench.environment.flushDelay = 1
        let told = OSAllocatedUnfairLock(initialState: 0)
        bench.environment.contentsChanged = { _ in told.withLock { $0 += 1 } }
        let archive = try archive()
        let temporary = ".afm-\(UUID().uuidString).tmp"
        try add(temporary, "arrived", to: archive)
        let due = clock.take()
        try archive.move(temporary, to: "arrived.txt", replacing: false)
        #expect(CoverageArchives.listed(box.url("changes.zip")).contains("arrived.txt") && !archive.hasPendingChanges)
        due.first?.work()
        #expect(told.withLock { $0 } == 1)
        try archive.setAttributes(FileAttributes(permissions: 0o600), of: "arrived.txt")
        let next = clock.take()
        try archive.commit()
        next.first?.work()
        #expect(told.withLock { $0 } == 2)
    }
}
