import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// An address the user typed is not asked about (N071; `ServerConsentService` of the kernel).
@MainActor
@Suite
internal struct Review2NetworkP2Consent {
    /// A server the user typed connects without a question, until it is disconnected.
    @Test
    internal func aServerTheUserNamedInPersonIsNotAskedAbout() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        let asked = Shared<[ServerKey]>([])
        fixture.environment.askToConnect = { profile in
            asked.modify { $0.append(profile.key) }
            return false
        }
        // An address that merely stood somewhere: asked, and No is no connection.
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.value == [fixture.key])
        // Typed by the user: the same server connects without a question.
        TypedAddresses(center: fixture.center).userChose(fixture.url("/pub/whatever"))
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(asked.value == [fixture.key])
        // After Disconnect the consent is gone with the connection.
        fixture.center.disconnect(fixture.key)
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.value.count == 2)
    }

    /// The top of a server is known from its address alone, without climbing and without a connection.
    ///
    /// Off the main thread: the climb through 3,000 levels takes seconds of a debug build, which other tests waited
    /// for when it ran there.
    @Test
    nonisolated internal func theTopOfAServerIsKnownFromTheAddressAlone() {
        let center = ConnectionCenter(environment: SessionEnvironment())
        let fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
        let key = ServerKey(scheme: "sftp", host: "files.example.com", port: 2_222)
        let deep = key.url(path: "/" + Array(repeating: "d", count: 3_000).joined(separator: "/"))
        // The same answer as climbing with `parent(of:)`, without the climb, and without a connection.
        var climbed = deep
        while let parent = fileSystem.parent(of: climbed) { climbed = parent }
        #expect(fileSystem.root(of: deep) == climbed && fileSystem.root(of: deep) == key.url())
        #expect(fileSystem.root(of: key.url()) == key.url())
        #expect(fileSystem.connectsToServer)
        #expect(!center.isConnected(key))
    }

    /// Typing a local folder, another scheme or another port of the same host gives no consent for this server.
    @Test
    internal func otherLocationsSayNothing() throws {
        let fixture = try FTPFixture()
        let asked = Shared<[ServerKey]>([])
        fixture.environment.askToConnect = { profile in
            asked.modify { $0.append(profile.key) }
            return false
        }
        let consent = TypedAddresses(center: fixture.center)
        consent.userChose(URL(fileURLWithPath: "/tmp"))
        consent.userChose(try #require(URL(string: "smb://127.0.0.1:\(fixture.server.port)/share")))
        // Another port of the same host is another server.
        consent.userChose(
            ServerKey(scheme: "ftp", host: "127.0.0.1", port: fixture.server.port == 21 ? 2_121 : 21).url(path: "/")
        )
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.value == [fixture.key])
    }

    /// News that the user chose the server does not drop the session whose login waits for a password.
    @Test
    internal func aLoginThatIsUnderWayIsNotDroppedByTheNews() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let login = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + Wait.ceiling) == .success)
        let session = try fixture.center.session(for: fixture.key)
        fixture.center.noteChosen(fixture.key)
        #expect(try fixture.center.session(for: fixture.key) === session)
        answer.signal()
        #expect(login.ended() && !login.failed)
    }
}
