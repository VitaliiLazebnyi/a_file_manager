import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Renaming onto an existing file never loses it (review 2: N005, N006, N007, N034).
@Suite
internal struct Review2NetworkReplacingMove {
    /// A server with `new.txt` and `keep.txt` (holding "new" and "old"), its options set by `configure`.
    private func fixture(
        _ configure: (inout TestFTPServer.Options) -> Void = { _ in
            // The server's defaults.
        }
    ) throws -> FTPFixture {
        var options = TestFTPServer.Options()
        configure(&options)
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/new.txt", "new")
        try fixture.box.file("srv/keep.txt", "old")
        return fixture
    }

    /// The files a replacing move left behind under a temporary name.
    private func leftovers(_ fixture: FTPFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.box.url("srv").path)
            .filter { name in
                name.contains(".replaced-")
            }
    }

    /// A move from a name that is not there fails before the destination is touched.
    @Test
    internal func aSourceThatDoesNotExistLeavesTheDestinationAlone() throws {
        let fixture = try fixture()
        #expect(throws: (any Error).self) {
            try fixture.fileSystem.move(fixture.url("/missing.txt"), to: fixture.url("/keep.txt"), replacing: true)
        }
        #expect(fixture.box.read("srv/keep.txt") == "old")
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
    }

    /// A server whose rename replaces gets one RNTO and no DELE.
    @Test
    internal func aServerThatReplacesDoesItInOneStep() throws {
        let fixture = try fixture()
        try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        #expect(fixture.box.read("srv/keep.txt") == "new" && !fixture.box.exists("srv/new.txt"))
        #expect(fixture.server.commands.filter { $0.hasPrefix("RNTO") }.count == 1)
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
    }

    /// A server whose rename does not replace gets the old file renamed aside and deleted last.
    @Test
    internal func aServerThatDoesNotReplaceGetsTheOldFileMovedAside() throws {
        let fixture = try fixture { $0.renameKeepsExisting = true }
        try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        #expect(fixture.box.read("srv/keep.txt") == "new" && !fixture.box.exists("srv/new.txt"))
        #expect(try leftovers(fixture).isEmpty)
        // The old file was deleted last, under its other name, never under its own.
        let commands = fixture.server.commands
        let deleted = commands.filter { $0.hasPrefix("DELE") }
        #expect(
            deleted.count == 1 && deleted[0].contains(".replaced-")
                && commands.last { $0.hasPrefix("RNTO") } == "RNTO /keep.txt"
        )
        let (deletion, renaming) = (
            try #require(commands.firstIndex(of: deleted[0])), try #require(commands.lastIndex(of: "RNTO /keep.txt"))
        )
        #expect(deletion > renaming)
        // The listings follow.
        #expect(try fixture.names("/") == ["keep.txt"])
    }

    /// A server that refuses the rename itself keeps both files as they were.
    @Test
    internal func aRenameThatIsRefusedForAnotherReasonLosesNothing() throws {
        // May delete, may not rename: the destination must not be the price.
        let fixture = try fixture { $0.refusesRenameOf = "*" }
        #expect(throws: NetworkError.self) {
            try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        }
        #expect(fixture.box.read("srv/keep.txt") == "old" && fixture.box.read("srv/new.txt") == "new")
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
        #expect(try leftovers(fixture).isEmpty)
    }

    /// When the old file was moved aside but the new one cannot take its name, the old one goes back.
    @Test
    internal func theOldFileIsPutBackWhenTheNewOneCannotTakeItsPlace() throws {
        // The file in the way can be moved aside, the new one cannot be renamed at all.
        let fixture = try fixture { options in
            options.renameKeepsExisting = true
            options.refusesRenameOf = "/new.txt"
        }
        #expect(throws: NetworkError.self) {
            try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        }
        #expect(fixture.box.read("srv/keep.txt") == "old" && fixture.box.read("srv/new.txt") == "new")
        #expect(try leftovers(fixture).isEmpty)
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
    }

    /// A folder with the destination's name is never deleted to make room for a file.
    @Test
    internal func aFolderInTheWayIsNotReplaced() throws {
        let fixture = try fixture { $0.renameKeepsExisting = true }
        try fixture.box.file("srv/dir/inside.txt", "i")
        #expect(throws: (any Error).self) {
            try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/dir"), replacing: true)
        }
        #expect(fixture.box.read("srv/dir/inside.txt") == "i" && fixture.box.read("srv/new.txt") == "new")
    }

    /// Whether a name that differs only in case is taken is for the server to say, not the listing.
    @Test
    internal func aNameThatDiffersOnlyInCaseIsAskedOfTheServer() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/file.txt", "there")
        _ = try fixture.names("/")
        // The listing knows `file.txt`. Whether `File.txt` is the same file is the server's to say
        // (this one, on a Mac's disk, says yes), not the listing's.
        #expect(throws: FileSystemError.self) { _ = try fixture.fileSystem.write(fixture.url("/File.txt")) }
        #expect(fixture.box.read("srv/file.txt") == "there")
        try fixture.box.file("srv/other.txt", "o")
        #expect(throws: FileSystemError.self) {
            try fixture.fileSystem.move(fixture.url("/other.txt"), to: fixture.url("/FILE.TXT"), replacing: false)
        }
        #expect(fixture.box.read("srv/file.txt") == "there")
    }

    /// A file made after the folder was listed is still not overwritten, since asking the server is cheap.
    @Test
    internal func aFileMadeBehindTheListingIsSeenWhereAskingIsCheap() throws {
        let fixture = try FTPFixture()
        _ = try fixture.names("/")
        // Made by somebody else a moment after the folder was read.
        try fixture.box.file("srv/fresh.txt", "theirs")
        #expect(throws: FileSystemError.self) { _ = try fixture.fileSystem.write(fixture.url("/fresh.txt")) }
        #expect(fixture.box.read("srv/fresh.txt") == "theirs")
    }
}
