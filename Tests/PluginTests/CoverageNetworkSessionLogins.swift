import AFMKernel
import Foundation
import Testing
import os

@testable import NetworkPlugin

/// Logins of an FTP session that keep failing, and entries of servers that tell little.
@Suite
internal struct CoverageNetworkSessionLogins {
    /// A password the server keeps refusing is asked for three times more, then the login fails.
    @Test
    internal func aRefusedPasswordIsAskedForThreeTimesMore() throws {
        let server = try CoverageNetworkServer(replies: ["USER": "331 Password", "PASS": "530 Login incorrect"])
        let center = server.center { _ in
            // The usual options.
        }
        let asked = OSAllocatedUnfairLock(initialState: 0)
        center.environment.askCredentials = { _, _ in
            asked.withLock { count in count += 1 }
            return Credentials(user: "anna", password: "wrong")
        }
        center.announce(ConnectionProfile(key: server.key, user: "anna", password: "first"), chosen: true)
        let error = #expect(throws: NetworkError.self) { try center.connect(server.key, cancellation: nil) }
        guard case .loginFailed = error else {
            Issue.record("not a failed login: \(String(describing: error))")
            return
        }
        #expect(asked.withLock { $0 } == 3)
        #expect(server.commands.filter { $0.hasPrefix("PASS") }.count == 4)
    }

    /// A guest named by hand logs in without a password.
    @Test
    internal func aGuestNamedByHandLogsInWithoutAPassword() throws {
        let server = try CoverageNetworkServer(replies: ["USER": "331 Password", "PASS": "230 Welcome"])
        let center = server.center { _ in
            // The usual options.
        }
        center.announce(ConnectionProfile(key: server.key, user: "anonymous"), chosen: true)
        _ = try center.connect(server.key, cancellation: nil)
        #expect(server.commands.contains("PASS "))
        center.disconnectAll()
    }

    /// Without MDTM a file has no date; a folder cannot be continued; an upload that MLST calls a
    /// folder is not measured.
    @Test
    internal func serversThatTellLittle() throws {
        let store: CoverageNetworkServer.Answer = .act { line in
            line.send("150 Send it")
            _ = line.receiveData()
            line.send("226 Stored")
        }
        let server = try CoverageNetworkServer(
            replies: [
                "FEAT": "211-Features:\r\n SIZE\r\n211 End", "SIZE /f": "213 3", "SIZE /d": "550 No",
                "STOR": store
            ]
        )
        let session = try server.session()
        defer { session.disconnect() }
        let file = try session.entry(at: "/f", cancellation: nil)
        #expect(file?.size == 3 && file?.modified == nil)
        let error = #expect(throws: NetworkError.self) { try session.openAppend("/d", at: nil, cancellation: nil) }
        #expect(CoverageNetworkServer.code(of: error) == 550)
        let folderServer = try CoverageNetworkServer(
            replies: [
                "FEAT": "211-Features:\r\n MLST type*;\r\n211 End", "STOR": store,
                "MLST /up": "250-Listing\r\n type=dir; /up\r\n250 End"
            ]
        )
        let other = try folderServer.session()
        defer { other.disconnect() }
        let writer = try other.openWrite("/up", cancellation: nil)
        try writer.write(Data("abc".utf8))
        try writer.close(attributes: FileAttributes())
    }

    /// The waits of a session can be lengthened and shortened.
    @Test
    internal func theWaitsCanBeChanged() throws {
        let server = try CoverageNetworkServer(replies: [:])
        let session = try #require(try server.session() as? FTPSession)
        session.returnGrace = 7
        session.stallLimit = 9
        #expect(session.returnGrace == 7 && session.stallLimit == 9)
    }
}
