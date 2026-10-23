import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The calls that change something end on the caller's flag (N010, N026; kernel API of the
/// first pass: `createDirectory`, `remove`, `move`, `setAttributes` with `cancellation`).
@Suite
internal struct Review2NetworkP2Cancelling {
    /// A server whose first login sits at its password question until `answer` is signalled.
    private struct HeldLogin {
        /// The server (`a.txt`, `d`) and the FTP file system.
        let fixture: FTPFixture
        /// Signalled, the password question is answered and the login goes on.
        let answer: DispatchSemaphore
        /// The listing that started the login.
        let first: AdoptOutcome
    }

    /// One of the four calls that change something, made with the flag it is given.
    private struct ChangingCall {
        /// The call's name, for the messages.
        let name: String
        /// Makes the call.
        let run: @Sendable (CancellationFlag) throws -> Void
    }

    /// A call of the test that waits, with the flag that ends it.
    private struct Waiting {
        /// The call's name, for the messages.
        let name: String
        /// The flag the call was given.
        let flag: CancellationFlag
        /// The call, running.
        let outcome: AdoptOutcome
    }

    /// A server with a password, its first login held at the question.
    private func heldAtLogin() throws -> HeldLogin {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options) { $0.timeout = 600 }
        try fixture.box.file("srv/a.txt", "a")
        try fixture.box.folder("srv/d")
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let first = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + Wait.ceiling) == .success)
        return HeldLogin(fixture: fixture, answer: answer, first: first)
    }

    /// `createDirectory`, `remove`, `move` and `setAttributes` of `fileSystem`, on the paths `/made`
    /// and `/a.txt` (moved to `/b.txt`) of the server `url` makes addresses for.
    private func changingCalls(
        of fileSystem: RemoteFileSystem,
        url: @escaping @Sendable (String) -> URL
    ) -> [ChangingCall] {
        [
            ChangingCall(name: "createDirectory") { flag in
                try fileSystem.createDirectory(at: url("/made"), cancellation: flag)
            },
            ChangingCall(name: "remove") { try fileSystem.remove(url("/a.txt"), cancellation: $0) },
            ChangingCall(name: "move") { flag in
                try fileSystem.move(url("/a.txt"), to: url("/b.txt"), replacing: true, cancellation: flag)
            },
            ChangingCall(name: "setAttributes") { flag in
                try fileSystem.setAttributes(FileAttributes(permissions: 0o600), of: url("/a.txt"), cancellation: flag)
            }
        ]
    }

    /// Each changing call of FTP that waits behind a login is ended by its own flag, and changes nothing.
    @Test
    internal func everyChangingCallOfAnFTPServerLeavesAWaitWhenItsFlagIsSet() throws {
        let held = try heldAtLogin()
        let fixture = held.fixture
        let fileSystem = fixture.fileSystem
        let calls = changingCalls(of: fileSystem) { fixture.url($0) }
        // All four wait behind the login, which nothing ends; each is ended by its own flag
        // alone. No time limit helps them here: the timeout is ten minutes.
        let waits = calls.map { call -> Waiting in
            let flag = CancellationFlag()
            return Waiting(name: call.name, flag: flag, outcome: AdoptOutcome { try call.run(flag) })
        }
        for waiting in waits {
            #expect(!waiting.outcome.ended(within: 0.3), "\(waiting.name) did not wait")
            waiting.flag.cancel()
            #expect(
                waiting.outcome.ended() && waiting.outcome.failed,
                "\(waiting.name) did not end when it was cancelled"
            )
        }
        // Nothing was changed, and the session is as good as before.
        held.answer.signal()
        #expect(held.first.ended() && !held.first.failed)
        #expect(try fixture.names("/") == ["a.txt", "d"])
        #expect(
            !fixture.server.commands.contains { command in
                ["MKD", "DELE", "RNFR", "SITE"].contains { command.hasPrefix($0) }
            }
        )
        // A flag that is set before the call: nothing is asked of the server at all.
        let set = CancellationFlag()
        set.cancel()
        let before = fixture.server.commands.count
        for call in calls { #expect(throws: (any Error).self) { try call.run(set) } }
        #expect(fixture.server.commands.count == before)
        // And with a flag that is never set they do their work.
        let unset = CancellationFlag()
        try fileSystem.createDirectory(at: fixture.url("/made/deeper"), cancellation: unset)
        try fileSystem.move(
            fixture.url("/a.txt"),
            to: fixture.url("/made/b.txt"),
            replacing: false,
            cancellation: unset
        )
        try fileSystem.setAttributes(
            FileAttributes(permissions: 0o600),
            of: fixture.url("/made/b.txt"),
            cancellation: unset
        )
        #expect(fixture.box.read("srv/made/b.txt") == "a")
        try fileSystem.remove(fixture.url("/made/b.txt"), cancellation: unset)
        try fileSystem.remove(fixture.url("/made/deeper"), cancellation: unset)
        #expect(try fixture.names("/made").isEmpty)
    }

    /// Each changing call to an SFTP server that never answers ends on its flag.
    @Test
    internal func aChangingCallOnASecureShellServerThatDoesNotAnswerEndsOnItsFlag() {
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 600
        environment.options.values = values
        // A "server" that never says a word: the login never ends, and every call waits behind it.
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(
                profile: profile,
                environment: environment,
                transport: SFTPTransport(executable: "/bin/sleep", arguments: ["600"])
            )
        }
        let key = ServerKey(scheme: "sftp", host: "silent.invalid")
        center.noteChosen(key)
        defer { center.disconnectAll() }
        let fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
        for call in changingCalls(of: fileSystem, url: { key.url(path: $0) }) {
            let flag = CancellationFlag()
            let outcome = AdoptOutcome { try call.run(flag) }
            #expect(!outcome.ended(within: 0.3), "\(call.name) did not wait")
            flag.cancel()
            #expect(outcome.ended() && outcome.failed, "\(call.name) did not end when it was cancelled")
        }
    }

    /// An SFTP request the server never answers ends on the flag, and nothing is removed.
    @Test
    internal func aRequestThatIsNeverAnsweredEndsOnTheFlag() throws {
        guard FakeSFTPServer.isAvailable else {
            return
        }
        // Logged in, and the server answers everything but the question about this one path.
        let suite = try NetworkFixSFTP(mode: .hangingStat, timeout: 600)
        try Data("x".utf8).write(to: suite.box.url("srv/hang"))
        _ = try suite.center.session(for: suite.key).connect(cancellation: nil)
        // Nothing is remembered of the folder: removing asks what the path is, and waits.
        let fresh = suite.fileSystem
        let flag = CancellationFlag()
        let outcome = AdoptOutcome { try fresh.remove(suite.url("/hang"), cancellation: flag) }
        #expect(!outcome.ended(within: 0.5))
        flag.cancel()
        #expect(outcome.ended() && outcome.failed)
        #expect(suite.box.exists("srv/hang"))
        suite.center.disconnectAll()
    }

    /// The flag made of two is set by either, and holds on to neither once the call is over.
    @Test
    internal func eitherFlagEndsTheWaitAndNothingIsLeftRegistered() {
        let (own, callers) = (CancellationFlag(), CancellationFlag())
        // The caller's flag.
        withEither(own, callers) { both in
            #expect(!both.isCancelled)
            callers.cancel()
            #expect(both.isCancelled)
        }
        // The session's own, and a flag that was set before.
        let second = CancellationFlag()
        withEither(own, second) { both in
            own.cancel()
            #expect(both.isCancelled)
        }
        withEither(own, CancellationFlag()) { #expect($0.isCancelled) }
        // Without a caller's flag the session's own is used as it is.
        let alone = CancellationFlag()
        withEither(alone, nil) { #expect($0 === alone) }
        // After the call nothing of it hangs on the flags: a later cancel reaches no stale flag.
        let (long, short) = (CancellationFlag(), CancellationFlag())
        weak var made: CancellationFlag?
        withEither(long, short) { made = $0 }
        #expect(made == nil)
        long.cancel()
    }
}
