import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import NetworkPlugin

/// The FTP client end to end, against the test server on 127.0.0.1: listings, transfers and changes.
@Suite
internal struct NetworkFTPTests {
    /// A folder lists with names, kinds, sizes and dates over MLSD and over LIST, hidden names only when
    /// asked, and a missing folder is an error.
    @Test(arguments: [true, false])
    internal func listsWithMLSDAndWithLIST(mlsd: Bool) throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = mlsd
        let fixture = try FTPFixture(options)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try fixture.box.file("srv/readme.txt", "hello", modified: old)
        try fixture.box.file("srv/.hidden", "h")
        try fixture.box.file("srv/name with spaces.dat", "12345678")
        try fixture.box.file("srv/pub/inner.txt", "i")

        let items = try fixture.fileSystem.list(fixture.url("/"), showHidden: false).sorted { $0.name < $1.name }
        #expect(items.map(\.name) == ["name with spaces.dat", "pub", "readme.txt"])
        #expect(items.map(\.isDirectory) == [false, true, false])
        #expect(items[0].size == 8 && items[2].size == 5)
        #expect(items[2].modified == old || abs(items[2].modified.timeIntervalSince(old)) < 86_400)
        #expect(items[0].url == fixture.url("/name with spaces.dat"))
        #expect(try fixture.names("/", showHidden: true).contains(".hidden"))
        #expect(try fixture.names("/pub") == ["inner.txt"])
        #expect(fixture.server.commands.contains { $0.hasPrefix("MLSD") } == mlsd)
        #expect(throws: (any Error).self) { try fixture.names("/missing") }
    }

    /// A DOS listing is read, and a server without EPSV is asked with PASV, EPSV not being tried again.
    @Test
    internal func listsDOSFormatAndWithoutEPSV() throws {
        var options = TestFTPServer.Options()
        (options.offersMLSD, options.dosListing, options.offersEPSV) = (false, true, false)
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "abc")
        try fixture.box.folder("srv/dir")
        let items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true).sorted { $0.name < $1.name }
        #expect(items.map(\.name) == ["a.txt", "dir"] && items[0].size == 3 && items[1].isDirectory)
        #expect(fixture.server.commands.contains("PASV"))
        // The refused EPSV is not tried again.
        _ = try fixture.names("/dir")
        #expect(fixture.server.commands.filter { $0 == "EPSV" }.count == 1)
    }

    /// In active mode the server connects back for listings and downloads.
    @Test
    internal func activeMode() throws {
        let fixture = try FTPFixture { $0.passiveByDefault = false }
        try fixture.box.file("srv/a.txt", "active")
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(try fixture.download("/a.txt") == Data("active".utf8))
        #expect(fixture.server.commands.contains { $0.hasPrefix("PORT") } && !fixture.server.commands.contains("EPSV"))
    }

    /// Files download whole or from an offset, upload with their date and permissions, and are never
    /// written over.
    @Test
    internal func downloadsUploadsAndResumes() throws {
        let fixture = try FTPFixture()
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try content.write(to: fixture.box.url("srv/big.bin"))
        #expect(try fixture.download("/big.bin") == content)
        // Resume: the rest from a position, fetched with REST.
        #expect(try fixture.download("/big.bin", from: 123_456) == content.subdata(in: 123_456..<content.count))
        #expect(fixture.server.commands.contains("REST 123456"))

        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.upload("/up.bin", content, attributes: FileAttributes(modified: stamp, permissions: 0o600))
        #expect(try Data(contentsOf: fixture.box.url("srv/up.bin")) == content)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.box.url("srv/up.bin").path)
        #expect(attributes[.modificationDate] as? Date == stamp)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        // An existing file is never overwritten by `write`.
        #expect(throws: FileSystemError.self) { try fixture.upload("/up.bin", Data("x".utf8)) }
        #expect(throws: (any Error).self) { _ = try fixture.download("/nothing.bin") }
    }

    /// Seeks forward and back while reading give the right bytes, and the interrupted connection still
    /// serves commands.
    @Test
    internal func seeksWhileReading() throws {
        let fixture = try FTPFixture()
        let content = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        try content.write(to: fixture.box.url("srv/f.bin"))
        let reader = try fixture.fileSystem.read(fixture.url("/f.bin"))
        defer { reader.close() }
        #expect(try reader.read(upToCount: 10) == content.prefix(10))
        // A short hop forward stays on the same transfer; a jump back starts a new one.
        try reader.seek(to: 1_000)
        #expect(try reader.read(upToCount: 5) == content.subdata(in: 1_000..<1_005))
        try reader.seek(to: 500_000)
        #expect(try reader.read(upToCount: 5) == content.subdata(in: 500_000..<500_005))
        try reader.seek(to: 3)
        #expect(try reader.read(upToCount: 4) == content.subdata(in: 3..<7))
        reader.close()
        // Closing returns at once and the server is told in the background. Once that is done,
        // the connection that was interrupted twice still serves commands.
        #expect(fixture.settle())
        #expect(try fixture.names("/") == ["f.bin"])
        #expect(fixture.server.connectionsOpened == 1)
    }

    /// Folders are made with their parents, moves replace only when asked, items are described, only empty
    /// folders are removed, and copying within the server is refused.
    @Test
    internal func makesRenamesAndDeletes() throws {
        let fixture = try FTPFixture()
        let remote = fixture.fileSystem
        try fixture.box.file("srv/a.txt", "a")
        try fixture.box.file("srv/b.txt", "b")
        try remote.createDirectory(at: fixture.url("/x/y/z"))
        #expect(fixture.box.exists("srv/x/y/z"))
        try remote.createDirectory(at: fixture.url("/x/y"))
        #expect(throws: FileSystemError.self) { try remote.createDirectory(at: fixture.url("/a.txt")) }

        try remote.move(fixture.url("/a.txt"), to: fixture.url("/x/moved.txt"), replacing: false)
        #expect(fixture.box.read("srv/x/moved.txt") == "a" && !fixture.box.exists("srv/a.txt"))
        #expect(throws: FileSystemError.self) {
            try remote.move(fixture.url("/b.txt"), to: fixture.url("/x/moved.txt"), replacing: false)
        }
        #expect(fixture.box.read("srv/x/moved.txt") == "a")
        try remote.move(fixture.url("/b.txt"), to: fixture.url("/x/moved.txt"), replacing: true)
        #expect(fixture.box.read("srv/x/moved.txt") == "b")

        #expect(remote.item(at: fixture.url("/x/moved.txt"))?.size == 1)
        #expect(remote.item(at: fixture.url("/x"))?.isDirectory == true)
        #expect(remote.item(at: fixture.url("/gone")) == nil)
        #expect(remote.item(at: fixture.url("/"))?.isDirectory == true)

        // A folder that is not empty stays; files and empty folders go.
        #expect(throws: (any Error).self) { try remote.remove(fixture.url("/x")) }
        try remote.remove(fixture.url("/x/moved.txt"))
        try remote.remove(fixture.url("/x/y/z"))
        try remote.remove(fixture.url("/x/y"))
        try remote.remove(fixture.url("/x"))
        #expect(!fixture.box.exists("srv/x"))
        #expect(throws: FileSystemError.self) {
            try remote.copy(fixture.url("/a"), to: fixture.url("/b")) { _ in true }
        }
    }

    /// The date and the permissions of a file are set on the server.
    @Test
    internal func changesAttributes() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        let stamp = Date(timeIntervalSince1970: 1_400_000_000)
        try fixture.fileSystem.setAttributes(
            FileAttributes(modified: stamp, permissions: 0o640),
            of: fixture.url("/a.txt")
        )
        let item = try #require(fixture.fileSystem.item(at: fixture.url("/a.txt")))
        #expect(item.modified == stamp && item.permissions == 0o640)
    }

    /// A single item is described from its folder's listing on a server without MLST, also without SIZE.
    @Test
    internal func itemWithoutMLST() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/d/a.txt", "abcd")
        #expect(fixture.fileSystem.item(at: fixture.url("/d/a.txt"))?.size == 4)
        #expect(fixture.fileSystem.item(at: fixture.url("/d"))?.isDirectory == true)
        #expect(fixture.fileSystem.item(at: fixture.url("/d/none")) == nil)
        fixture.server.options.offersSize = false
        fixture.center.disconnect(fixture.key)
        #expect(fixture.fileSystem.item(at: fixture.url("/d/a.txt"))?.size == 4)
        #expect(fixture.fileSystem.item(at: fixture.url("/d"))?.isDirectory == true)
    }

    /// The automatic mode sends text files in ASCII with CR LF line ends and other files unchanged.
    @Test
    internal func textModeConvertsLineEnds() throws {
        let fixture = try FTPFixture { $0.transferMode = .automatic }
        try fixture.upload("/note.txt", Data("one\ntwo\r\nthree\n".utf8))
        #expect(try Data(contentsOf: fixture.box.url("srv/note.txt")) == Data("one\r\ntwo\r\nthree\r\n".utf8))
        #expect(try fixture.download("/note.txt") == Data("one\ntwo\nthree\n".utf8))
        // Anything that is not on the list of text files travels unchanged.
        try fixture.upload("/note.bin", Data("one\n".utf8))
        #expect(try Data(contentsOf: fixture.box.url("srv/note.bin")) == Data("one\n".utf8))
        #expect(fixture.server.commands.contains("TYPE A") && fixture.server.commands.contains("TYPE I"))
    }

    /// Names in UTF-8 travel both ways, and a name with a line end cannot smuggle in a command.
    @Test
    internal func unicodeNames() throws {
        let fixture = try FTPFixture()
        try fixture.upload("/Grüße & 日本語.txt", Data("ü".utf8))
        #expect(try fixture.names("/") == ["Grüße & 日本語.txt"])
        #expect(try fixture.download("/Grüße & 日本語.txt") == Data("ü".utf8))
        #expect(fixture.server.commands.contains("OPTS UTF8 ON"))
        #expect(throws: (any Error).self) { try fixture.fileSystem.createDirectory(at: fixture.url("/a\r\nDELE x")) }
        #expect(!fixture.server.commands.contains("DELE x"))
    }
}
