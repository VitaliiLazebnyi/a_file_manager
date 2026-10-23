import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Links resolved after the listing, and servers that want the TLS session reused.
@Suite
internal struct NetworkAdoptFTPLinks {
    /// Links beyond those asked about during the listing are resolved in the background, and the next
    /// listing knows them all.
    @Test
    internal func linksBeyondTheProbeLimitAreResolvedAfterTheListing() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/d")
        for index in 0..<40 {
            try FileManager.default.createSymbolicLink(
                at: fixture.box.url("srv/link\(index)"),
                withDestinationURL: fixture.box.url("srv/d")
            )
        }
        let first = try fixture.fileSystem.list(fixture.url("/"), showHidden: false).filter(\.isSymlink)
        #expect(first.count == 40)
        // Only some could be asked within the limit...
        #expect(first.filter(\.isDirectory).count < 40)
        // ... the rest follows in the background, and the next listing knows.
        func allResolved() -> Bool {
            let links = (try? fixture.fileSystem.list(fixture.url("/"), showHidden: false))?.filter(\.isSymlink) ?? []
            return links.count == 40 && links.allSatisfy(\.isDirectory)
        }
        #expect(adoptWait(until: allResolved))
    }

    /// Links resolved in the background are folders in the listing the file system remembers, too.
    @Test
    internal func aLinkResolvedInTheBackgroundIsAFolderInWhatTheFileSystemRemembers() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/d")
        for index in 0..<40 {
            try FileManager.default.createSymbolicLink(
                at: fixture.box.url("srv/link\(index)"),
                withDestinationURL: fixture.box.url("srv/d")
            )
        }
        // Time stands still for the session and for what the file system remembers: the background work does not
        // give up on the links (it would after 20 s), and the remembered listing does not age (it would after 10 s).
        let now = Date()
        fixture.environment.clock = { now }
        let fileSystem = RemoteFileSystem(scheme: "ftp", center: fixture.center) { now }
        // The listing is remembered by the file system, with some links not resolved yet.
        let listed = try fileSystem.list(fixture.url("/"), showHidden: false).filter(\.isSymlink)
        #expect(listed.count == 40 && listed.filter(\.isDirectory).count < 40)
        // The server is asked about every link in the background, and the remembered entries say so, too.
        func asked() -> Int { Set(fixture.server.commands.filter { $0.hasPrefix("CWD /link") }).count }
        #expect(adoptWait { asked() == 40 })
        func allFolders() -> Bool {
            (0..<40).allSatisfy { fileSystem.item(at: fixture.url("/link\($0)"))?.isDirectory == true }
        }
        #expect(adoptWait(until: allFolders))
    }

    /// Replies that ask for the TLS session to be reused are recognised, and their error says so.
    @Test
    internal func aServerThatWantsTheTLSSessionReusedGetsAnUnderstandableError() {
        func reply(_ code: Int, _ text: String) -> FTPReply { FTPReply(code: code, lines: [text]) }
        #expect(FTPConnection.requiresSessionReuse(reply(522, "SSL connection failed; session reuse required")))
        #expect(FTPConnection.requiresSessionReuse(reply(522, "Data connection must use cached TLS session")))
        #expect(
            FTPConnection.requiresSessionReuse(
                reply(425, "Unable to build data connection: TLS session of data connection not resumed.")
            )
        )
        #expect(FTPConnection.requiresSessionReuse(reply(421, "TLS session reuse required")))
        #expect(!FTPConnection.requiresSessionReuse(reply(425, "Can't open data connection")))
        #expect(!FTPConnection.requiresSessionReuse(reply(550, "No such file")))
        #expect(!FTPConnection.requiresSessionReuse(reply(226, "session reuse")))
        let message = NetworkError.sessionReuseRequired("522 session reuse required").errorDescription ?? ""
        #expect(message.contains("reuse") && message.contains("522 session reuse required"))
        #expect(!NetworkError.sessionReuseRequired("x").isConnectionLevel)
    }
}
