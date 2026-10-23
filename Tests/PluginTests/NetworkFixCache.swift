import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The directory cache keeps up with what this program does, and the cost of a copy stays linear.
@Suite
internal struct NetworkFixCache {
    private func lists(_ fixture: FTPFixture) -> Int {
        fixture.server.commands.filter { $0 == "LIST -la" || $0 == "LIST" }.count
    }

    /// Twelve uploads to a server without MLST, each with the checks a copy job makes, list the folder a
    /// few times in all, not three times for each file.
    @Test
    internal func manyUploadsToAServerWithoutMLSTListTheFolderOnce() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/in")
        _ = try fixture.center.connect(fixture.key)
        for index in 0..<12 {
            let target = fixture.url("/in/file\(index).dat")
            let content = Data(repeating: UInt8(index), count: 1_000 + index)
            // The checks a copy job makes before it writes.
            #expect(fixture.fileSystem.item(at: target) == nil)
            #expect(fixture.fileSystem.item(at: target) == nil)
            try fixture.upload(
                "/in/file\(index).dat",
                content,
                attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000))
            )
            let item = try #require(fixture.fileSystem.item(at: target))
            #expect(item.size == Int64(content.count) && item.modified == Date(timeIntervalSince1970: 1_600_000_000))
        }
        // One listing for the first question, one for the first file; not three for each of twelve.
        #expect(lists(fixture) <= 3, "\(lists(fixture)) listings")
        #expect(try fixture.names("/in").count == 12)
    }

    /// Removing from a folder that was listed sends DELE for files and RMD for folders without trying the
    /// other first, and the cache knows they are gone.
    @Test
    internal func removingFromAListedFolderAsksNoQuestions() throws {
        let fixture = try FTPFixture()
        for index in 0..<6 { try fixture.box.file("srv/d/f\(index).txt", "x") }
        try fixture.box.folder("srv/d/sub")
        _ = try fixture.names("/d")
        for index in 0..<6 { try fixture.fileSystem.remove(fixture.url("/d/f\(index).txt")) }
        try fixture.fileSystem.remove(fixture.url("/d/sub"))
        let commands = fixture.server.commands
        // Files go with DELE and the folder with RMD, without trying the wrong one first.
        #expect(commands.filter { $0.hasPrefix("DELE") }.count == 6)
        #expect(commands.filter { $0.hasPrefix("RMD") }.count == 1)
        let before = commands.count
        #expect(fixture.fileSystem.item(at: fixture.url("/d/f0.txt")) == nil)
        #expect(fixture.server.commands.count == before)
        #expect(try fixture.names("/d").isEmpty)
    }

    /// A rename is entered into both cached listings without listing again; reading a folder again asks
    /// the server.
    @Test
    internal func aRenameIsEnteredIntoTheListings() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "abc")
        try fixture.box.folder("srv/sub")
        _ = try fixture.names("/")
        _ = try fixture.names("/sub")
        let before = lists(fixture)
        try fixture.fileSystem.move(fixture.url("/a.txt"), to: fixture.url("/sub/b.txt"), replacing: false)
        #expect(fixture.fileSystem.item(at: fixture.url("/a.txt")) == nil)
        #expect(fixture.fileSystem.item(at: fixture.url("/sub/b.txt"))?.size == 3)
        #expect(lists(fixture) == before)
        // A listing read again always asks the server.
        try fixture.box.file("srv/sub/outside.txt", "o")
        #expect(try fixture.names("/sub") == ["b.txt", "outside.txt"])
    }

    /// A folder made is known at once, and making it again sends nothing.
    @Test
    internal func aFolderMadeIsKnownAtOnce() throws {
        let fixture = try FTPFixture()
        _ = try fixture.names("/")
        try fixture.fileSystem.createDirectory(at: fixture.url("/new"))
        let before = fixture.server.commands.count
        #expect(fixture.fileSystem.item(at: fixture.url("/new"))?.isDirectory == true)
        #expect(fixture.server.commands.count == before)
        // Making it again is no error and sends nothing.
        try fixture.fileSystem.createDirectory(at: fixture.url("/new"))
        #expect(fixture.server.commands.filter { $0.hasPrefix("MKD") }.count == 1)
    }

    /// A writer dropped without closing makes the folder's listing unknown, so it is asked for again.
    @Test
    internal func anAbandonedUploadMakesTheFolderBeReadAgain() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        _ = try fixture.center.connect(fixture.key)
        _ = try fixture.names("/")
        var writer: (any FileWriter)? = try fixture.fileSystem.write(fixture.url("/partial.bin"))
        try writer?.write(Data(repeating: 1, count: 100))
        // Dropped without close: what the folder holds is not known any more.
        writer = nil
        let before = fixture.server.commands.count
        _ = fixture.fileSystem.item(at: fixture.url("/partial.bin"))
        #expect(fixture.server.commands.count > before)
    }
}
