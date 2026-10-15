import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The last resort before quitting, and archives that live on another file system: saving
/// new members elsewhere, sending the archive back, and asking whether it is still current.
@Suite
internal struct CoverageArchivesRescueTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A bench of its own for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    private func add(_ path: String, _ text: String, to archive: OpenArchive) throws {
        let writer = try archive.write(path)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    /// A ZIP on the memory file system ("a server"), opened.
    private func remote(_ name: String) throws -> (url: URL, archive: OpenArchive) {
        let local = try CoverageArchives.zip("\(name)-local.zip", in: box, ["a.txt": "a"], options: [])
        let url = bench.memory.url("/server/\(name).zip")
        bench.memory.createDirectory(at: url.deletingLastPathComponent())
        let writer = try bench.memory.write(url)
        try writer.write(try Data(contentsOf: local))
        try writer.close(attributes: FileAttributes())
        return (url, try bench.store.archive(at: url))
    }

    /// Checks that new members are saved in an archive of their own next to the archive,
    /// under a name not taken yet, even when the archive's name has no known extension.
    @Test
    internal func newMembersAreSavedUnderAFreeName() throws {
        let url = try CoverageArchives.zip("data.bin", in: box, ["a.txt": "a"], options: [])
        let archive = try bench.store.archive(at: url)
        try add("one.txt", "one", to: archive)
        try box.file("data (unsaved changes).zip", "taken")
        guard case .saved(let saved) = archive.rescue() else {
            Issue.record("the new member was not saved")
            return
        }
        #expect(saved.lastPathComponent == "data (unsaved changes 2).zip")
        #expect(CoverageArchives.contents(of: "one.txt", in: saved) == "one")
    }

    /// Checks that when nothing can be written next to the archive, the recovery folder is used.
    @Test
    internal func theRecoveryFolderTakesWhatTheArchivesFolderCannot() throws {
        try box.folder("locked")
        let url = try CoverageArchives.zip("locked/archive.zip", in: box, ["a.txt": "a"], options: [])
        let archive = try bench.store.archive(at: url)
        try add("one.txt", "one", to: archive)
        bench.environment.recoveryFolder = box.url("recovery")
        #expect(chmod(box.url("locked").path, 0o555) == 0)
        defer { chmod(box.url("locked").path, 0o755) }
        guard case .saved(let saved) = archive.rescue() else {
            Issue.record("the new member was not saved")
            return
        }
        #expect(saved.deletingLastPathComponent().lastPathComponent == "recovery")
    }

    /// Checks that members whose data cannot be copied any more are kept as they are, with a
    /// list; an empty member, which has no data, is left out of it.
    @Test
    internal func membersThatCannotBeCopiedAreKeptWithAList() throws {
        let url = try CoverageArchives.zip("lost.zip", in: box, ["a.txt": "a"], options: [])
        let archive = try bench.store.archive(at: url)
        try add("one.txt", "one", to: archive)
        try add("empty.txt", "", to: archive)
        let scratch = bench.environment.scratch.url
        for name in try FileManager.default.contentsOfDirectory(atPath: scratch.path) where name.hasSuffix(".zipdata") {
            try FileManager.default.removeItem(at: scratch.appendingPathComponent(name))
        }
        guard case .kept(let folder) = archive.rescue() else {
            Issue.record("the members were not kept")
            return
        }
        let lists = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("index-") }
        let index = try String(contentsOf: folder.appendingPathComponent(try #require(lists.first)), encoding: .utf8)
        #expect(index.contains("\tone.txt\t") && !index.contains("\tempty.txt\t"))
        #expect(!namesOnDisk(box.root).contains { $0.contains("unsaved changes") })
    }

    /// Checks that when only members without data wait, the list is kept in the temporary folder.
    @Test
    internal func onlyEmptyMembersLeaveTheListInTheTemporaryFolder() throws {
        let url = try CoverageArchives.zip("empty.zip", in: box, ["a.txt": "a"], options: [])
        let archive = try bench.store.archive(at: url)
        try add("empty.txt", "", to: archive)
        guard case .kept(let folder) = archive.rescue(quickly: true) else {
            Issue.record("the member was not kept")
            return
        }
        #expect(folder == bench.environment.scratch.url)
    }

    /// Checks that the new members of an archive from another file system are not saved next
    /// to it, where the plugin cannot write by itself.
    @Test
    internal func membersOfARemoteArchiveAreNotSavedNextToIt() throws {
        let (_, archive) = try remote("rescued")
        try add("one.txt", "one", to: archive)
        guard case .kept = archive.rescue() else {
            Issue.record("the member was saved next to a remote archive")
            return
        }
    }

    /// Checks sending a changed archive back: refused without file systems, ended when the
    /// progress says so, and given up when the transfer is interrupted; then done.
    @Test
    internal func aChangedRemoteArchiveIsSentBack() throws {
        let (url, archive) = try remote("sent")
        try add("one.txt", "one", to: archive)
        let fileSystems = bench.fileSystems
        bench.environment.fileSystems = { nil }
        #expect {
            try archive.commit()
        } throws: { error in
            guard case ArchiveError.readOnly = error else {
                return false
            }
            return true
        }
        bench.environment.fileSystems = { fileSystems }
        #expect {
            try archive.commit { _, _ in false }
        } throws: { error in
            guard case ArchiveError.cancelled = error else {
                return false
            }
            return true
        }
        // A transfer that stalls is interrupted when the commit is cancelled.
        bench.memory.stallsWrites = true
        let flag = CancellationFlag()
        let failed = Signal<Bool>()
        OtherThread.start {
            failed.set((try? archive.commit(cancellation: flag)) == nil)
        }
        #expect(Wait.until { bench.memory.stalledTransfers > 0 })
        flag.cancel()
        #expect(failed.wait() == true)
        bench.memory.stallsWrites = false
        #expect(!bench.memory.allPaths.contains { $0.hasSuffix(".tmp") })
        try archive.commit()
        let reader = try bench.memory.read(url)
        var data = Data()
        while let block = try reader.read(upToCount: 1 << 16) {
            data.append(block)
        }
        try data.write(to: box.url("downloaded.zip"))
        #expect(CoverageArchives.listed(box.url("downloaded.zip")).sorted() == ["a.txt", "one.txt"])
    }

    /// Checks when a remote archive counts as current: not without file systems or once it
    /// is gone from the server; yes when the question was given up, or when there was nothing
    /// to compare with yet.
    @Test
    internal func whetherARemoteArchiveIsCurrentIsAskedOfItsServer() throws {
        let fileSystems = bench.fileSystems
        let lonely = try remote("lonely").archive
        bench.environment.fileSystems = { nil }
        #expect(!lonely.isCurrent())
        bench.environment.fileSystems = { fileSystems }
        let flag = CancellationFlag()
        flag.cancel()
        #expect(try remote("asked").archive.isCurrent(cancellation: flag))
        let (gone, archive) = try remote("gone")
        try bench.memory.remove(gone)
        #expect(!archive.isCurrent())

        let (url, _) = try remote("unstamped")
        let copy = box.url("unstamped-copy.zip")
        try FileManager.default.copyItem(at: box.url("unstamped-local.zip"), to: copy)
        let unstamped = try OpenArchive(
            archiveURL: url,
            localURL: copy,
            fetchedCopy: TemporaryFile(copy),
            remoteStamp: nil,
            environment: bench.environment
        )
        #expect(unstamped.isCurrent())
    }
}
