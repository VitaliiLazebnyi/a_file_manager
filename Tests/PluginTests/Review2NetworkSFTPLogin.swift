import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The login through the secure shell (review 2: N089, N091, N092, N097, N099).
@Suite
internal struct Review2NetworkSFTPLogin {
    /// Stands in for `ssh`: asks for the password the way ssh does, through the same helper, and
    /// is the system's SFTP server once the right one came. `prompt` is the question it asks.
    private func fakeShell(_ box: Sandbox, prompt: String, password: String) throws -> SFTPTransport {
        let script = try box.file(
            "fake-ssh.sh",
            """
            #!/bin/sh
            answer=$("$SSH_ASKPASS" "\(prompt)")
            if [ "$answer" != "\(password)" ]; then
              echo "Permission denied (password)." >&2
              exit 255
            fi
            exec \(LocalSSHServer.systemSFTPServer) -e

            """
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return SFTPTransport(executable: script.path, asksQuestions: true)
    }

    /// A stored password that fails is asked for, the one that works is kept, and a refusal is not asked again at once.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: LocalSSHServer.systemSFTPServer)))
    internal func aStoredPasswordThatIsWrongIsAskedForAgain() throws {
        let box = try Sandbox()
        try box.file("srv/a.txt", "a")
        let environment = SessionEnvironment()
        environment.declineMemory = 0
        let key = ServerKey(scheme: "sftp", host: "files.example")
        let profile = ConnectionProfile(key: key, savedID: UUID(), user: "anna", password: "stale")
        let session = SFTPSession(
            profile: profile,
            environment: environment,
            transport: try fakeShell(box, prompt: "anna@files.example's password: ", password: "right")
        )
        defer { session.disconnect() }
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var questions: [String] = []
        nonisolated(unsafe) var answers = ["right"]
        environment.askSecret = { _, question, _ in
            questions.append(question)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var remembered: [String] = []
        environment.rememberPassword = { _, password in remembered.append(password) }
        // The stored password is tried without a question; when it fails the user is asked, and
        // what works takes its place.
        _ = try session.connect(cancellation: nil)
        #expect(questions == ["anna@files.example's password: "] && remembered == ["right"])
        #expect(session.profile.password == "right")
        #expect(try session.entry(at: box.url("srv/a.txt").path)?.size == 1)

        // A stored password that is right asks nothing.
        questions = []
        let good = SFTPSession(
            profile: ConnectionProfile(key: key, user: "anna", password: "right"),
            environment: environment,
            transport: try fakeShell(box, prompt: "anna@files.example's password: ", password: "right")
        )
        defer { good.disconnect() }
        _ = try good.connect(cancellation: nil)
        #expect(questions.isEmpty && remembered == ["right"])

        // The user gives up: remembered as a refusal, nothing stored.
        environment.declineMemory = 600
        let refused = SFTPSession(
            profile: profile,
            environment: environment,
            transport: try fakeShell(box, prompt: "anna@files.example's password: ", password: "right")
        )
        defer { refused.disconnect() }
        #expect(throws: NetworkError.self) { _ = try refused.connect(cancellation: nil) }
        #expect(questions.count == 1 && remembered == ["right"])
        #expect(throws: NetworkError.self) { _ = try refused.connect(cancellation: nil) }
        #expect(questions.count == 1, "not asked again right away")
    }

    /// Questions of a jump host or a server's own text never get the stored password, and say whose words they are.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: LocalSSHServer.systemSFTPServer)))
    internal func whatAServerOrAJumpHostAsksIsNotAnsweredWithTheStoredPassword() throws {
        let box = try Sandbox()
        let environment = SessionEnvironment()
        environment.declineMemory = 0
        let profile = ConnectionProfile(
            key: ServerKey(scheme: "sftp", host: "files.example"),
            user: "anna",
            password: "stored"
        )
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var shown: [String] = []
        environment.askSecret = { _, question, _ in
            shown.append(question)
            return "typed"
        }
        // A jump host, a question that names nobody, and a server that writes what looks like a
        // question about a key on this Mac: none of them gets the stored password, and the
        // user sees whose words they are.
        for prompt in [
            "anna@jump.example's password: ", "Password: ",
            "(anna@files.example) Enter passphrase for key '/Users/a/.ssh/id': "
        ] {
            let session = SFTPSession(
                profile: profile,
                environment: environment,
                transport: try fakeShell(box, prompt: prompt, password: "typed")
            )
            _ = try session.connect(cancellation: nil)
            session.disconnect()
        }
        #expect(shown.count == 3)
        #expect(shown[0] == "anna@jump.example's password: ")
        #expect(shown[1].contains("may come from the server") && shown[1].hasSuffix("Password: "))
        #expect(shown[2].contains("The server files.example asks") && shown[2].contains("comes from the server"))
        // Asked by this server for this login, the stored one is given without a question.
        let own = SFTPSession(
            profile: profile,
            environment: environment,
            transport: try fakeShell(box, prompt: "(anna@files.example) Password: ", password: "stored")
        )
        _ = try own.connect(cancellation: nil)
        own.disconnect()
        #expect(shown.count == 3)
    }

    /// The real `ssh` with the options the program gives it, against a secure-shell server of
    /// the system on 127.0.0.1 that shows a banner made to look like an error.
    @Test(.enabled(if: LocalSSHServer.isAvailable))
    internal func theRealShellTakesTheOptionsAndTheBannerIsNotShownAsTheError()
        throws
    {
        let box = try Sandbox()
        let banner = "BANNER-TEXT: your account is locked, run this command to unlock it"
        let server = try LocalSSHServer(box: box, passphrase: "open sesame", banner: banner)
        defer { server.stop() }
        try box.file("srv/hello.txt", "over ssh")
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (20, 0)
        let key = ServerKey(scheme: "sftp", host: "127.0.0.1", port: server.port)
        // What only the test needs (its own keys and known hosts) first, then the program's own
        // arguments as they are: ssh takes the first value it is given for an option.
        let own = Array(server.clientArguments.dropLast(6))
        let arguments =
            own + SFTPSession.sshArguments(for: ConnectionProfile(key: key, user: NSUserName()), options: values)
        let environment = SessionEnvironment()
        environment.options.values = values
        environment.declineMemory = 0
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        let passphrase = Shared("wrong")
        environment.askSecret = { _, _, isSecret in isSecret ? passphrase.value : "yes" }
        func session() -> SFTPSession {
            SFTPSession(
                profile: ConnectionProfile(key: key, user: NSUserName()),
                environment: environment,
                transport: SFTPTransport(executable: "/usr/bin/ssh", arguments: arguments, asksQuestions: true)
            )
        }
        // A login that fails: the message is ssh's own, not the server's banner.
        let failing = session()
        do {
            _ = try failing.connect(cancellation: nil)
            Issue.record("the login with a wrong passphrase went through")
        } catch {
            #expect(!error.localizedDescription.contains("BANNER-TEXT"), "\(error.localizedDescription)")
            #expect(
                error.localizedDescription.lowercased().contains("permission denied"),
                "\(error.localizedDescription)"
            )
        }
        failing.disconnect()
        // With the right passphrase ssh accepts every option it was given and the files are there.
        passphrase.value = "open sesame"
        let working = session()
        defer { working.disconnect() }
        _ = try working.connect(cancellation: nil)
        #expect(try working.entry(at: box.url("srv/hello.txt").path)?.size == 8)
    }
}
