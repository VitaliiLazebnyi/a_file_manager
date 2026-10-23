import TestSupport
import Testing

@testable import NetworkPlugin

/// Logging in to an SFTP server: questions, a login that waits for another, and logins that end on the way.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct CovNetSFTPLogin {
    /// What ssh's questions are, by the words around them.
    @Test
    internal func questionsAreToldByTheirWords() {
        #expect(SSHQuestion("(anna@example.org)") == .server(user: "anna", host: "example.org", text: ""))
        #expect(SSHQuestion("Please type 'yes', 'no' or the fingerprint: ") == .hostKey)
        #expect(SSHQuestion("(nobody) Password:") == .other)
        #expect(SSHQuestion("(@example.org) Password:") == .other)
        #expect(SSHQuestion("(anna@two words) Password:") == .other)
    }

    /// A notice of ssh (touch the security key) is logged, and the login goes on.
    @Test
    internal func aNoticeIsLoggedAndTheLoginGoesOn() throws {
        let bench = try CovNetSFTPBench()
        let session = bench.session(
            transport: try bench.asking("SSH_ASKPASS_PROMPT=none \"$SSH_ASKPASS\" 'Touch your security key' >/dev/null")
        )
        defer { session.disconnect() }
        #expect(try session.connect(cancellation: nil) == "/")
        #expect(bench.log.contains("Touch your security key"))
        #expect(bench.log.contains { $0.hasPrefix("Logged in to ") && $0.hasSuffix(", at /") })
    }

    /// A login that waits behind another one which asks the user ends when the session is disconnected.
    @Test
    internal func aLoginBehindAnotherEndsWithTheSession() throws {
        let bench = try CovNetSFTPBench()
        let asked = Signal<Bool>()
        let answer = Signal<Bool>()
        bench.environment.askSecret = { _, _, _ in
            asked.set(true)
            _ = answer.wait()
            return nil
        }
        let session = bench.session(transport: try bench.asking("\"$SSH_ASKPASS\" \"anna@fake.invalid's password:\""))
        let first = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(asked.wait() == true)
        let second = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        session.disconnect()
        #expect(second.ended() && CovNetErrorKind(second.thrown) == .notConnected)
        answer.set(true)
        #expect(first.ended() && first.failed)
    }

    /// A login that waits behind another one which makes no progress and asks nothing gives up.
    @Test
    internal func aLoginBehindOneThatMakesNoProgressGivesUp() throws {
        let bench = try CovNetSFTPBench(timeout: 60)
        let session = bench.session(transport: SFTPTransport(executable: "/bin/sleep", arguments: ["600"]))
        session.stallLimit = 0.2
        #expect(session.stallLimit == 0.2)
        let first = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(Wait.until { session.isConnecting })
        let second = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(second.ended() && CovNetErrorKind(second.thrown) == .busy)
        session.disconnect()
        #expect(first.ended() && first.failed)
    }

    /// A server the user does not want to connect to is not connected to, and not asked about again at once.
    @Test
    internal func aServerTheUserDeclinesIsNotAskedAboutAgainAtOnce() throws {
        let bench = try CovNetSFTPBench()
        let questions = CovNetCount()
        bench.environment.askToConnect = { _ in
            questions.add()
            return false
        }
        var profile = ConnectionProfile(key: bench.key)
        profile.asksBeforeConnecting = true
        let session = bench.session(profile)
        defer { session.disconnect() }
        for _ in 0..<2 {
            let error = #expect(throws: NetworkError.self) { _ = try session.connect(cancellation: nil) }
            #expect(CovNetErrorKind(error) == .cancelled)
        }
        #expect(questions.value == 1)
    }

    /// A session that is disconnected while the user is asked whether to connect starts nothing.
    @Test
    internal func aSessionDisconnectedWhileAskingStartsNothing() throws {
        let bench = try CovNetSFTPBench()
        var profile = ConnectionProfile(key: bench.key)
        profile.asksBeforeConnecting = true
        let session = bench.session(profile)
        bench.environment.askToConnect = { [weak session] _ in
            session?.disconnect()
            return true
        }
        let error = #expect(throws: NetworkError.self) { _ = try session.connect(cancellation: nil) }
        #expect(CovNetErrorKind(error) == .notConnected)
        #expect(!bench.log.contains { $0.hasPrefix("Connect to") })
    }

    /// A session that is disconnected just after the login keeps no channel.
    @Test
    internal func aSessionDisconnectedAfterTheLoginKeepsNoChannel() throws {
        let bench = try CovNetSFTPBench()
        let session = bench.session()
        bench.environment.log = { [weak session] line in
            if line.hasPrefix("Logged in") { session?.disconnect() }
        }
        let error = #expect(throws: NetworkError.self) { _ = try session.connect(cancellation: nil) }
        #expect(CovNetErrorKind(error) == .notConnected)
        #expect(!session.isConnected && !session.isConnecting)
    }

    /// A user name that ssh would take for an option is refused before ssh runs.
    @Test
    internal func aUserNameThatLooksLikeAnOptionIsRefused() throws {
        let bench = try CovNetSFTPBench()
        let session = SFTPSession(
            profile: ConnectionProfile(key: bench.key, user: "-oProxyCommand=touch"),
            environment: bench.environment,
            transport: nil
        )
        let error = #expect(throws: NetworkError.self) { _ = try session.connect(cancellation: nil) }
        #expect(CovNetErrorKind(error) == .loginFailed)
        #expect(bench.log.isEmpty)
    }

    /// A server whose first answer names no request is a failed login.
    @Test
    internal func aServerWhoseAnswerNamesNoRequestIsAFailedLogin() throws {
        let bench = try CovNetSFTPBench(mode: .shortPacket)
        let session = bench.session()
        defer { session.disconnect() }
        let error = #expect(throws: NetworkError.self) { _ = try session.connect(cancellation: nil) }
        #expect(CovNetErrorKind(error) == .loginFailed)
    }
}
