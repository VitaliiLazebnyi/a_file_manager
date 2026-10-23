import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Writing the changes into the archive file while others change it: another program that
/// replaces the file, members removed meanwhile, renames that write at once and fail.
@Suite
internal struct CoverageArchivesWriteTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }
    private var url: URL { box.url("write.zip") }

    /// A bench of its own for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A ZIP with a few members, opened.
    private func opened(_ options: [String] = []) throws -> OpenArchive {
        _ = try CoverageArchives.zip(
            "write.zip",
            in: box,
            ["file.txt": "file", "target.txt": "target", "folder/inner.txt": "inner"],
            options: options
        )
        return try bench.store.archive(at: url, cancellation: nil)
    }

    /// Another archive, for putting in the place of the one under test.
    private func stranger(_ files: [String: String], options: [String]) throws -> URL {
        try CoverageArchives.zip("stranger-\(UUID().uuidString).zip", in: box, files, options: options)
    }

    private func add(_ path: String, _ text: String, to archive: OpenArchive) throws {
        let writer = try archive.write(path, level: nil, password: nil)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    private func read(_ archive: OpenArchive, _ path: String) throws -> String {
        let stream = try archive.open(try #require(archive.entry(path)), slot: nil)
        defer { stream.close() }
        return try #require(String(bytes: try stream.readFully(1 << 20), encoding: .utf8))
    }

    private func isChangedOutside(_ error: any Error) -> Bool {
        guard case ArchiveError.changedOutside = error else {
            return false
        }
        return true
    }

    /// Checks that a write whose archive file is replaced, or whose folder takes no new file,
    /// while the new file is made changes nothing and leaves no temporary file behind.
    @Test
    internal func aWriteThatCannotPutItsFileInPlaceChangesNothing() throws {
        let archive = try opened()
        try add("new.txt", "new", to: archive)
        let other = try stranger(["other.txt": "other"], options: [])
        bench.environment.whileWriting = { [url] in try? CoverageArchives.replace(url, with: other) }
        #expect { try archive.commit(cancellation: nil) { _, _ in true } } throws: { isChangedOutside($0) }
        #expect(archive.hasPendingChanges && CoverageArchives.listed(url) == ["other.txt"])
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".afm-zip.tmp") })
        bench.store.close()

        let again = try opened()
        try add("new.txt", "new", to: again)
        bench.environment.whileWriting = { [box] in _ = chmod(box.root.path, 0o555) }
        defer { chmod(box.root.path, 0o755) }
        #expect(throws: (any Error).self) { try again.commit(cancellation: nil) { _, _ in true } }
        chmod(box.root.path, 0o755)
        bench.environment.whileWriting = nil
        try again.commit(cancellation: nil) { _, _ in true }
        #expect(CoverageArchives.listed(url).contains("new.txt"))
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".afm-zip.tmp") })
    }

    /// Checks that a member removed while the file was written, which the file holds all the
    /// same, is taken out by the next write, which is due like any other.
    @Test
    internal func aMemberRemovedWhileTheFileIsWrittenGoesWithTheNextWrite() throws {
        let clock = CoverageArchivesClock()
        bench.environment.schedule = { [clock] in clock.schedule($0, $1, $2) }
        bench.environment.flushDelay = 1
        let archive = try opened()
        try add("gone.txt", "gone", to: archive)
        bench.environment.whileWriting = { try? archive.remove("gone.txt") }
        try archive.commit(cancellation: nil) { _, _ in true }
        bench.environment.whileWriting = nil
        #expect(CoverageArchives.listed(url).contains("gone.txt") && archive.hasPendingChanges)
        #expect(!clock.take().isEmpty)
        try archive.commit(cancellation: nil) { _, _ in true }
        #expect(!CoverageArchives.listed(url).contains("gone.txt") && CoverageArchives.isSound(url))
    }

    /// Checks that after another program replaced the archive, the new members join what it
    /// holds now under names of their own, new folders join once, and the loss of the other
    /// changes is reported.
    @Test
    internal func aReplacedArchiveTakesTheNewMembersUnderNamesOfTheirOwn() throws {
        let archive = try opened(["-D"])
        try add("README", "mine", to: archive)
        try add("notes.txt", "mine", to: archive)
        try archive.makeDirectory("shared")
        try archive.makeDirectory("mine")
        try archive.remove("file.txt")
        let other = box.url("other.zip")
        let theirs = [(name: "README", data: Data("theirs".utf8)), (name: "notes.txt", data: Data("theirs".utf8))]
        try CoverageArchives.craft(other, theirs + [(name: "shared/", data: Data())], localExtra: nil) { record in
            if record.name.hasSuffix("/") {
                record = .new(
                    name: record.name,
                    isDirectory: true,
                    modified: Date(),
                    permissions: 0o755,
                    isSymbolicLink: false
                )
            }
        }
        try CoverageArchives.replace(url, with: other)
        #expect { try archive.commit(cancellation: nil) { _, _ in true } } throws: { isChangedOutside($0) }
        let listed = CoverageArchives.listed(url)
        #expect(listed.contains("README (2)") && listed.contains("notes (2).txt") && listed.contains("mine/"))
        #expect(listed.filter { $0 == "shared/" }.count == 1)
        #expect(CoverageArchives.contents(of: "README (2)", in: url) == "mine")
    }

    /// Checks that an archive replaced by one that lists a name twice is not written into.
    @Test
    internal func aReplacementThatListsANameTwiceIsNotWrittenInto() throws {
        let archive = try opened()
        try add("new.txt", "new", to: archive)
        let twice = box.url("twice.zip")
        try CoverageArchives.craft(
            twice,
            [(name: "a.txt", data: Data("1".utf8)), (name: "a.txt", data: Data("2".utf8))],
            localExtra: nil
        ) { _ in
            // Every record as it is.
        }
        try CoverageArchives.replace(url, with: twice)
        #expect { try archive.commit(cancellation: nil) { _, _ in true } } throws: { isChangedOutside($0) }
        #expect(CoverageArchives.listed(url) == ["a.txt", "a.txt"])
    }

    /// Checks that a rename that wrote at once and failed is taken back: the replaced member
    /// is back (one from the file, and one that was waiting), and the new one is on its way again.
    @Test(arguments: [true, false])
    internal func aRenameWhoseWriteFailsIsTakenBack(replacingAMemberOfTheFile: Bool) throws {
        let archive = try opened()
        let target = replacingAMemberOfTheFile ? "target.txt" : "waiting.txt"
        if !replacingAMemberOfTheFile {
            try add(target, "waiting", to: archive)
        }
        let temporary = ".afm-\(UUID().uuidString).tmp"
        try add(temporary, "arrived", to: archive)
        let other = try stranger(["other.txt": "other"], options: [])
        bench.environment.whileWriting = { [url] in try? CoverageArchives.replace(url, with: other) }
        #expect { try archive.move(temporary, to: target, replacing: true) } throws: { isChangedOutside($0) }
        bench.environment.whileWriting = nil
        #expect(try read(archive, target) == (replacingAMemberOfTheFile ? "target" : "waiting"))
        #expect(try read(archive, temporary) == "arrived")
    }

    /// Checks that a rename whose archive was replaced before it wrote keeps what the archive
    /// was read anew with, and reports the changes that were lost.
    @Test
    internal func aRenameIntoAReplacedArchiveKeepsWhatWasReadAnew() throws {
        let archive = try opened()
        try archive.remove("file.txt")
        let temporary = ".afm-\(UUID().uuidString).tmp"
        try add(temporary, "arrived", to: archive)
        try CoverageArchives.replace(url, with: try stranger(["other.txt": "other"], options: []))
        #expect { try archive.move(temporary, to: "arrived.txt", replacing: false) } throws: { isChangedOutside($0) }
        #expect(try read(archive, "arrived.txt") == "arrived" && archive.entry(temporary) == nil)
        #expect(CoverageArchives.listed(url) == ["other.txt", "arrived.txt"])
    }

    /// Checks that a rename that writes at once leaves out members that are still arriving
    /// under their real names, and writes a member again that is already in the file.
    @Test
    internal func aRenameThatWritesAtOnceWritesOnlyItsOwnMember() throws {
        let archive = try opened()
        try add("arriving.txt", "arriving", to: archive)
        let temporary = ".afm-\(UUID().uuidString).tmp"
        try add(temporary, "arrived", to: archive)
        try archive.move(temporary, to: "arrived.txt", replacing: false)
        #expect(
            CoverageArchives.listed(url).contains("arrived.txt")
                && !CoverageArchives.listed(url).contains("arriving.txt")
        )
        #expect(archive.hasPendingChanges)
        try archive.commit(cancellation: nil) { _, _ in true }
        try archive.move("arriving.txt", to: "renamed.txt", replacing: false)
        #expect(CoverageArchives.contents(of: "renamed.txt", in: url) == "arriving" && !archive.hasPendingChanges)
    }

    /// Checks that a rename that would write at once does not wait behind a long write; the
    /// member is written with the next one.
    @Test
    internal func aRenameDoesNotWaitBehindALongWrite() throws {
        let archive = try opened()
        try add("pending.txt", "pending", to: archive)
        let (entered, release) = (Signal<Bool>(), Signal<Bool>())
        bench.environment.whileWriting = {
            entered.set(true)
            _ = release.wait()
        }
        let done = Signal<Bool>()
        OtherThread.start {
            done.set((try? archive.commit(cancellation: nil) { _, _ in true }) != nil)
        }
        #expect(entered.wait() == true)
        let temporary = ".afm-\(UUID().uuidString).tmp"
        try add(temporary, "arrived", to: archive)
        try archive.move(temporary, to: "arrived.txt", replacing: false)
        release.set(true)
        #expect(done.wait() == true)
        bench.environment.whileWriting = nil
        #expect(!CoverageArchives.listed(url).contains("arrived.txt") && archive.hasPendingChanges)
        try archive.commit(cancellation: nil) { _, _ in true }
        #expect(CoverageArchives.listed(url).contains("arrived.txt"))
    }

    /// Checks that a member renamed while the file is written is found by its position, and
    /// its new name is written next time.
    @Test
    internal func aMemberRenamedWhileTheFileIsWrittenKeepsItsData() throws {
        let archive = try opened()
        try add("moving.txt", "moving", to: archive)
        bench.environment.whileWriting = { try? archive.move("moving.txt", to: "moved.txt", replacing: false) }
        try archive.commit(cancellation: nil) { _, _ in true }
        bench.environment.whileWriting = nil
        #expect(CoverageArchives.listed(url).contains("moving.txt") && archive.hasPendingChanges)
        #expect(try read(archive, "moved.txt") == "moving")
        try archive.commit(cancellation: nil) { _, _ in true }
        #expect(CoverageArchives.contents(of: "moved.txt", in: url) == "moving")
        #expect(!CoverageArchives.listed(url).contains("moving.txt"))
    }

    /// Checks that new members join an archive that another program replaced without a word
    /// of loss, when nothing else was changed here.
    @Test
    internal func newMembersJoinAReplacedArchiveWithoutLoss() throws {
        let archive = try opened()
        #expect(archive.entry("folder")?.isImplicit == true)
        try add("new.txt", "new", to: archive)
        try CoverageArchives.replace(url, with: try stranger(["other.txt": "other"], options: []))
        try archive.commit(cancellation: nil) { _, _ in true }
        #expect(CoverageArchives.listed(url).sorted() == ["new.txt", "other.txt"])
    }
}
