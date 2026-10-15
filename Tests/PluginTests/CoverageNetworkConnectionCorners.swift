import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Single commands and listings of an FTP connection at their edges: names in fixed encodings,
/// folders removed from inside, refused verdicts, MLSD that is announced but missing.
@Suite
internal struct CoverageNetworkConnectionCorners {
    /// A RETR that opens the data connection and holds it until the client drops it.
    private static let heldDownload: CoverageNetworkServer.Answer = .act { line in
        line.sendAndWaitForTheClient(Data())
        line.send("426 Aborted")
    }

    /// Names in a fixed encoding are read with it, or as UTF-8 when they are not of it.
    @Test
    internal func namesInAFixedEncodingAreReadWithIt() {
        #expect(NameEncoding.isoLatin1.decodeTelling(Data([0x63, 0xE9])) == ("c\u{E9}", .isoLatin1))
        #expect(NameEncoding.utf8.decodeTelling(Data([0x63, 0xFF])) == ("c\u{FFFD}", .utf8))
        // Not UTF-8, and not Windows Latin 1 either.
        #expect(NameEncoding.automatic.decodeTelling(Data([0x63, 0x81])) == ("c\u{FFFD}", .utf8))
    }

    /// A folder the connection stands in is left before it is removed.
    @Test
    internal func aFolderIsLeftBeforeItIsRemoved() throws {
        let server = try CoverageNetworkServer(replies: ["RMD": "250 Removed"])
        let connection = try server.connected()
        defer { connection.close() }
        try connection.changeDirectory("/a/b")
        try connection.removeDirectory("/a")
        #expect(server.commands.suffix(3) == ["CWD /a/b", "CWD /", "RMD /a"])
    }

    /// The time of a file is read from MDTM, and is unknown when the server does not tell it.
    @Test
    internal func theTimeOfAFileIsReadFromMDTM() throws {
        let server = try CoverageNetworkServer(
            replies: ["MDTM /a": "213 20240102030405", "MDTM /b": "550 No such file"]
        )
        let connection = try server.connected()
        defer { connection.close() }
        #expect(try connection.modificationTime(of: "/a") == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(try connection.modificationTime(of: "/b") == nil)
    }

    /// A transfer the server calls failed at the end is an error, and the connection stays usable.
    @Test
    internal func aTransferRefusedAtTheEndIsAnError() throws {
        let server = try CoverageNetworkServer(
            replies: ["RETR": .act { line in line.transfer(Data("x".utf8), verdict: "451 Local error") }]
        )
        let connection = try server.connected()
        defer { connection.close() }
        let stream = try connection.beginTransfer("RETR a", type: "I")
        while try stream.read(upToCount: 10, timeout: 10) != nil {
            // Read to the end.
        }
        let error = #expect(throws: NetworkError.self) { try connection.finishTransfer() }
        #expect(CoverageNetworkServer.code(of: error) == 451)
        #expect(connection.isUsable)
    }

    /// A transfer on a connection that broke meanwhile is dropped without waiting for a reply.
    @Test
    internal func aTransferOnABrokenConnectionIsDropped() throws {
        let server = try CoverageNetworkServer(replies: ["RETR": Self.heldDownload])
        let connection = try server.connected()
        defer { connection.close() }
        _ = try connection.beginTransfer("RETR a", type: "I")
        #expect(throws: NetworkError.self) { try connection.send("NOOP", replyWithin: 0) }
        connection.abortTransfer()
        #expect(!connection.isUsable)
    }

    /// MLSD that is announced but refused is given up for LIST.
    @Test
    internal func mlsdThatIsRefusedIsGivenUpForLIST() throws {
        let line = Data("-rw-r--r-- 1 u g 5 Jan 01 2020 listed.txt\r\n".utf8)
        let server = try CoverageNetworkServer(
            replies: [
                "FEAT": "211-Features:\r\n MLSD\r\n MLST type*;\r\n211 End",
                "MLSD": "500 Unknown command",
                "LIST": .act { control in control.transfer(line, verdict: "226 Done") }
            ]
        )
        let connection = try server.connected()
        defer { connection.close() }
        var names: [String] = []
        try connection.list("/", showHidden: false) { entries in
            names += entries.map(\.name)
            return true
        }
        #expect(names == ["listed.txt"] && !connection.offersMLSD)
    }

    /// An MLSD name in another encoding is remembered with it.
    @Test
    internal func anMLSDNameInAnotherEncodingIsRemembered() throws {
        var listing = Data("type=file;size=1; caf".utf8)
        listing.append(contentsOf: [0xE9, 0x0D, 0x0A])
        let data = listing
        let server = try CoverageNetworkServer(
            replies: [
                "FEAT": "211-Features:\r\n MLSD\r\n211 End",
                "OPTS": "501 No options",
                "MLSD": .act { control in control.transfer(data, verdict: "226 Done") }
            ]
        )
        let connection = try server.connected()
        defer { connection.close() }
        var names: [String] = []
        try connection.list("/", showHidden: false) { entries in
            names += entries.map(\.name)
            return true
        }
        #expect(names == ["caf\u{E9}"])
        #expect(connection.knownNames.encoding(of: Array("caf\u{E9}".utf8)) == .windowsCP1252)
    }
}
