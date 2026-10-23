import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Who may connect where, and with what (review 2: N030, N031, N068, N071, N085, N087).
@Suite
internal struct Review2NetworkConsent {
    /// A server the user did not choose in a dialog or save is asked about once per session first.
    @Test
    internal func aServerNobodyChoseIsAskedAbout() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var asked: [ConnectionProfile] = []
        // Written by the other thread before it signals, read here after the wait.
        let allows = Shared(false)
        fixture.environment.askToConnect = { profile in
            asked.append(profile)
            return allows.value
        }
        // A location from a tab file or a list: no login is made without the user's yes.
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.count == 1 && asked[0].key == fixture.key && asked[0].asksBeforeConnecting)
        #expect(!fixture.server.commands.contains { $0.hasPrefix("USER") })
        allows.value = true
        #expect(try fixture.names("/") == ["a.txt"])
        // Once for the session, not for every connection of it.
        DispatchQueue.concurrentPerform(iterations: 4) { _ in _ = try? fixture.names("/") }
        #expect(asked.count == 2)

        // A connection the user made in a dialog of the program is not asked about.
        let chosen = try FTPFixture()
        chosen.environment.askToConnect = { [key = chosen.key] _ in
            asked.append(ConnectionProfile(key: key))
            return false
        }
        chosen.center.announce(ConnectionProfile(key: chosen.key, anonymous: true), chosen: true)
        #expect(try chosen.names("/").isEmpty && asked.count == 2)
        // Nor a saved one.
        let saved = try FTPFixture()
        saved.environment.askToConnect = { _ in false }
        saved.center.setSaved([ConnectionProfile(key: saved.key, savedID: UUID(), anonymous: true)])
        #expect(try saved.names("/").isEmpty)
    }

    /// Reading the same address again while its login waits for a password keeps that session.
    @Test
    internal func aTypedAddressDoesNotDropALoginThatIsUnderWay() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "a")
        let text = "ftp://anna@127.0.0.1:\(fixture.server.port)/"
        #expect(fixture.fileSystem.location(from: text) == fixture.url("/"))
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let login = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + Wait.ceiling) == .success)
        let session = try fixture.center.session(for: fixture.key)
        #expect(session.isConnecting)
        // The same text is read again while the user types the password (a panel that refreshes
        // its path field), and another with a password: the session at its question stays.
        #expect(fixture.fileSystem.location(from: text) == fixture.url("/"))
        #expect(
            fixture.fileSystem.location(from: "ftp://anna:other@127.0.0.1:\(fixture.server.port)/") == fixture.url("/")
        )
        #expect(try fixture.center.session(for: fixture.key) === session)
        answer.signal()
        #expect(login.ended() && !login.failed)
        #expect(fixture.center.isConnected(fixture.key))
    }

    /// A password over plain FTP is sent only after a yes, asked once, and kept only once the server took it.
    @Test
    internal func aPasswordOnPlainFTPIsAskedAboutAndStoredOnlyOnceAccepted() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "right")
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "a")
        fixture.environment.asksAboutUnprotectedLoopback = true
        let id = UUID()
        fixture.center.setSaved([ConnectionProfile(key: fixture.key, savedID: id, user: "anna")])
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var warnings = 0
        let allows = Shared(false)
        fixture.environment.askToSendPasswordUnprotected = { _ in
            warnings += 1
            return allows.value
        }
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var answers = ["wrong", "right"]
        fixture.environment.askCredentials = { _, _ in
            Credentials(user: "anna", password: answers.removeFirst(), remember: true)
        }
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var remembered: [String] = []
        fixture.environment.rememberPassword = { profile, password in
            if profile.savedID == id { remembered.append(password) }
        }
        // Refused: no password leaves the machine.
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(warnings == 1 && !fixture.server.commands.contains { $0.hasPrefix("PASS") })
        answers = ["wrong", "right"]
        allows.value = true
        #expect(try fixture.names("/") == ["a.txt"])
        // Asked once, not for each attempt; and only the password the server took is kept.
        #expect(warnings == 2 && remembered == ["right"])
        #expect(fixture.server.commands.filter { $0.hasPrefix("PASS") } == ["PASS wrong", "PASS right"])
        #expect(
            FTPSession.isLoopback("127.0.0.1") && FTPSession.isLoopback("localhost") && FTPSession.isLoopback("::1")
        )
        #expect(!FTPSession.isLoopback("ftp.example.com") && !FTPSession.isLoopback("10.0.0.1"))
    }

    /// The trusted certificates are fetched once, when a connection first needs them, host names in any case.
    @Test
    internal func certificatesAcceptedForGoodAreNotReadFromTheSettings() {
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var loads = 0
        let trust = CertificateTrust {
            loads += 1
            return ["Files.Example.com": ["AA:BB"]]
        }
        // Nothing is fetched before a connection needs it.
        #expect(!trust.isAccepted("AA:BB", for: "files.example.com") && loads == 0)
        trust.prepare()
        trust.prepare()
        #expect(loads == 1 && trust.isAccepted("AA:BB", for: "FILES.example.com"))
        // A certificate that changed takes the place of the old one; it is not added to it.
        trust.accept("CC:DD", for: "files.example.com")
        #expect(trust.fingerprints(for: "files.example.com") == ["AA:BB", "CC:DD"])
        trust.replace(with: "EE:FF", for: "Files.example.com")
        #expect(
            trust.fingerprints(for: "files.example.com") == ["EE:FF"]
                && !trust.isAccepted("AA:BB", for: "files.example.com")
        )
    }
}
