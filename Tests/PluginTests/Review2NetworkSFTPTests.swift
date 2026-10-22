import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Uploads over SFTP are only a success when the server has all of the file
/// (review 2: N038, N040, and the length of every upload).
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct Review2NetworkSFTPUploads {
    private func upload(_ suite: NetworkFixSFTP, _ content: Data) throws {
        let writer = try suite.fileSystem.write(suite.url("/up.bin"))
        do {
            for start in stride(from: 0, to: content.count, by: 100_000) {
                try writer.write(content.subdata(in: start..<min(start + 100_000, content.count)))
            }
        } catch {
            // A refusal may show at a later write or at the closing; the closing is what counts.
            try? writer.close(attributes: FileAttributes())
            throw error
        }
        try writer.close(attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000)))
    }

    @Test
    internal func aGoodUploadIsMeasuredAndConfirmed() throws {
        let suite = try NetworkFixSFTP()
        let content = NetworkFixSFTP.pattern(700_000)
        try upload(suite, content)
        #expect(try Data(contentsOf: suite.box.url("srv/up.bin")) == content)
        // The length was asked for (fstat), and the closing was waited for.
        let log = try String(contentsOf: suite.box.url("sftp-requests.log"), encoding: .utf8).split(separator: "\n")
        #expect(log.contains("8") && log.last == "4")
    }

    @Test
    internal func aClosingThatFailsIsAFailedUpload() throws {
        let suite = try NetworkFixSFTP(mode: .failingClose)
        #expect(throws: (any Error).self) { try upload(suite, NetworkFixSFTP.pattern(50_000)) }
        // Reading is not affected: the closing of a handle that was only read tells nothing.
        try NetworkFixSFTP.pattern(1_000).write(to: suite.box.url("srv/r.bin"))
        let reader = try suite.fileSystem.read(suite.url("/r.bin"))
        #expect(try reader.read(upToCount: 2_000)?.count == 1_000)
        reader.close()
    }

    @Test
    internal func aRefusedWriteLeavesNoGapBehind() throws {
        let suite = try NetworkFixSFTP(mode: .failingWrite)
        let content = NetworkFixSFTP.pattern(900_000)
        #expect(throws: (any Error).self) { try upload(suite, content) }
        // The writes behind the refused one were on their way and were carried out. What is left
        // on the server is cut back to the first byte that was not confirmed: a true start of the file.
        let stored = suite.box.url("srv/up.bin")
        #expect(adoptWait { ((try? Data(contentsOf: stored))?.count ?? -1) == 65_536 })
        #expect(try Data(contentsOf: stored) == content.prefix(65_536))
    }

    @Test
    internal func aServerThatForgetsWhatItConfirmedIsNoticed() throws {
        let suite = try NetworkFixSFTP(mode: .forgetfulWrite)
        #expect(throws: NetworkError.self) { try upload(suite, NetworkFixSFTP.pattern(300_000)) }
    }
}

/// The shared channel (review 2: N035, N036, N037, N060, N063, N064, N090, N093, N094, N095).
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct Review2NetworkSFTPChannel {
    @Test
    internal func aServerThatSaysNothingAtAllIsGivenUp() throws {
        let suite = try NetworkFixSFTP(mode: .hangingStat, timeout: 1)
        try NetworkFixSFTP.pattern(1_000).write(to: suite.box.url("srv/f.bin"))
        let session = try suite.center.session(for: suite.key)
        _ = try session.connect(cancellation: nil)
        #expect(try session.entry(at: "/f.bin")?.size == 1_000)
        // Nothing arrives for the whole time a request may take: the line is taken for dead, so
        // the requests that follow do not each wait out their own time on it.
        #expect(throws: NetworkError.self) { _ = try session.entry(at: "/hang") }
        // The next request opens a new channel and is answered.
        #expect(try session.entry(at: "/f.bin")?.size == 1_000)
        let starts = try String(contentsOf: suite.box.url("sftp-requests.log"), encoding: .utf8).split(separator: "\n")
            .filter { $0 == "16" }
        #expect(starts.count == 2, "a second login was made")
    }

    @Test
    internal func closingAHandleNeverWaitsAndComesBeforeWhatFollows() throws {
        let suite = try NetworkFixSFTP(mode: .normal, timeout: 10)
        try NetworkFixSFTP.pattern(200_000).write(to: suite.box.url("srv/f.bin"))
        let session = try suite.center.session(for: suite.key)
        for _ in 0..<20 {
            let reader = try suite.fileSystem.read(suite.url("/f.bin"))
            #expect(try reader.read(upToCount: 100)?.count == 100)
            reader.close()
            // Asked right after the closing: the server sees the closing first.
            #expect(try session.entry(at: "/f.bin")?.size == 200_000)
        }
        let log = try String(contentsOf: suite.box.url("sftp-requests.log"), encoding: .utf8).split(separator: "\n")
            .map(String.init)
        // open (3) … close (4) … lstat (7): never an lstat between a file's last read and its close.
        var open = 0
        for kind in log {
            if kind == "3" { open += 1 }
            if kind == "4" { open -= 1 }
            if kind == "7" { #expect(open == 0, "a question overtook the closing of a handle") }
        }
        #expect(log.filter { $0 == "4" }.count == 20)
    }

    @Test
    internal func disconnectEndsALoginThatIsUnderWay() throws {
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 60
        environment.options.values = values
        // A "server" that never says a word.
        let session = SFTPSession(
            profile: ConnectionProfile(key: ServerKey(scheme: "sftp", host: "silent.invalid")),
            environment: environment,
            transport: SFTPTransport(executable: "/bin/sleep", arguments: ["600"])
        )
        let login = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(adoptWait { session.isConnecting })
        // A second caller without a flag waits behind the login.
        let waiting = AdoptOutcome { try session.makeDirectory("/x", cancellation: nil) }
        let started = Date()
        session.disconnect()
        #expect(Date().timeIntervalSince(started) < 60, "closing returns at once")
        #expect(login.ended() && login.failed)
        #expect(waiting.ended() && waiting.failed)
        #expect(!session.isConnected && !session.isConnecting)
        // Nothing is stored in a session that was closed.
        #expect(throws: NetworkError.self) { _ = try session.entry(at: "/") }
    }

    @Test
    internal func aChannelClosedBeforeItStartsDoesNotStart() {
        // A disconnect may close the channel before the login starts it; the closed pipe must
        // not be touched (its handle raises, which ended the whole program).
        let channel = SFTPChannel(executable: "/bin/sleep", arguments: ["600"], environment: [:])
        channel.close()
        #expect(throws: NetworkError.self) { try channel.start(timeout: 30, cancellation: nil) { true } }
        #expect(channel.isClosed)
    }

    @Test
    internal func aPacketThatIsNotSFTPEndsTheChannelAndItsProcess() throws {
        // Announces a packet far larger than any the protocol has, after the greeting.
        let box = try Sandbox()
        let script = try box.file(
            "big.py",
            """
            import os, struct, sys, time
            os.read(0, 9)
            os.write(1, struct.pack(">IBI", 5, 2, 3))
            os.read(0, 1 << 16)
            os.write(1, struct.pack(">I", 0x7fffffff) + b"x" * 1000)
            time.sleep(600)
            """
        )
        let channel = SFTPChannel(executable: FakeSFTPServer.python, arguments: [script.path], environment: [:])
        try channel.start(timeout: Wait.ceiling, cancellation: nil) { true }
        #expect(throws: NetworkError.self) { _ = try channel.request(.realpath, timeout: 30) { $0.string(".") } }
        #expect(adoptWait { channel.isClosed })
        #expect(SFTPChannel.largestPacket <= 1 << 20)
    }

    @Test
    internal func cancellingOneWriterInTheMiddleOfAPacketLeavesTheChannelToTheOthers() throws {
        let suite = try NetworkFixSFTP(mode: .normal, timeout: 20)
        try NetworkFixSFTP.pattern(400_000).write(to: suite.box.url("srv/f.bin"))
        let session = try suite.center.session(for: suite.key)
        // Uploads that are interrupted while their packets are being written, one after the other.
        for round in 0..<8 {
            let writer = try suite.fileSystem.write(suite.url("/up\(round).bin"))
            let writing = AdoptOutcome { for _ in 0..<40 { try writer.write(NetworkFixSFTP.pattern(200_000)) } }
            Thread.sleep(forTimeInterval: 0.05)
            writer.interrupt()
            #expect(writing.ended())
            try? writer.close(attributes: FileAttributes())
        }
        // The channel is the same one, and still carries the others.
        #expect(session.isConnected)
        #expect(try session.entry(at: "/f.bin")?.size == 400_000)
        let logins = try String(contentsOf: suite.box.url("sftp-requests.log"), encoding: .utf8).split(separator: "\n")
            .filter { $0 == "16" }
        #expect(logins.count == 1, "the channel was closed by a cancelled upload")
    }
}

/// Renaming over SFTP (review 2: N005, N034), against a server whose rename does not replace
/// and against the system's own.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct Review2NetworkSFTPRename {
    @Test
    internal func aServerWithoutReplacingRenameGetsTheOldFileMovedAside() throws {
        let suite = try NetworkFixSFTP(mode: .strictRename)
        try suite.box.file("srv/new.txt", "new")
        try suite.box.file("srv/keep.txt", "old")
        try suite.fileSystem.move(suite.url("/new.txt"), to: suite.url("/keep.txt"), replacing: true)
        #expect(suite.box.read("srv/keep.txt") == "new" && !suite.box.exists("srv/new.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: suite.box.url("srv").path).sorted() == ["keep.txt"])
    }

    @Test
    internal func aRefusalForAnotherReasonLosesNothing() throws {
        let suite = try NetworkFixSFTP(mode: .strictRename)
        try suite.box.file("srv/locked", "new")
        try suite.box.file("srv/keep.txt", "old")
        // The source cannot be renamed at all; the file in the way is moved aside and put back.
        #expect(throws: (any Error).self) {
            try suite.fileSystem.move(suite.url("/locked"), to: suite.url("/keep.txt"), replacing: true)
        }
        #expect(suite.box.read("srv/keep.txt") == "old" && suite.box.read("srv/locked") == "new")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: suite.box.url("srv").path).sorted() == [
                "keep.txt", "locked"
            ]
        )
        // A source that is not there.
        #expect(throws: (any Error).self) {
            try suite.fileSystem.move(suite.url("/none"), to: suite.url("/keep.txt"), replacing: true)
        }
        #expect(suite.box.read("srv/keep.txt") == "old")
    }
}

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: systemSFTPServer)))
internal struct Review2NetworkSFTPSystemServer {
    internal let box: Sandbox
    internal let center: ConnectionCenter
    internal let fileSystem: RemoteFileSystem
    internal let key = ServerKey(scheme: "sftp", host: "test.invalid")

    internal init() throws {
        box = try Sandbox()
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 10
        environment.options.values = values
        center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(
                profile: profile,
                environment: environment,
                transport: SFTPTransport(executable: systemSFTPServer, arguments: ["-e"])
            )
        }
        fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
    }

    internal func url(_ path: String) -> URL { key.url(path: box.url(path).path) }

    @Test
    internal func renamingReplacesOnlyWhenAsked() throws {
        try box.file("new.txt", "new")
        try box.file("keep.txt", "old")
        _ = try fileSystem.list(url(""), showHidden: true)
        // A file made by somebody else after the folder was read: the listing does not know it,
        // the server does, and a rename that must not replace does not.
        try box.file("fresh.txt", "theirs")
        #expect(throws: FileSystemError.self) {
            try fileSystem.move(url("new.txt"), to: url("fresh.txt"), replacing: false)
        }
        #expect(box.read("fresh.txt") == "theirs" && box.read("new.txt") == "new")
        // Asked to replace, it does, in one step.
        try fileSystem.move(url("new.txt"), to: url("keep.txt"), replacing: true)
        #expect(box.read("keep.txt") == "new" && !box.exists("new.txt"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: box.root.path).sorted() == ["fresh.txt", "keep.txt"]
        )
        // A source that does not exist loses nothing.
        #expect(throws: (any Error).self) {
            try fileSystem.move(url("none.txt"), to: url("keep.txt"), replacing: true)
        }
        #expect(box.read("keep.txt") == "new")
    }

    @Test
    internal func uploadsAreMeasuredAndNamesGoBackAsTheyCame() throws {
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let writer = try fileSystem.write(url("up.bin"))
        try writer.write(content)
        try writer.close(
            attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000), permissions: 0o640)
        )
        #expect(try Data(contentsOf: box.url("up.bin")) == content)
        #expect(fileSystem.item(at: url("up.bin"))?.size == 300_000)
        // A name stored decomposed is found again under the name the listing showed.
        try box.file("u\u{308}ber.txt", "content")
        let listed = try #require(
            try fileSystem.list(url(""), showHidden: true).first { $0.name.hasSuffix("ber.txt") }
        )
        let reader = try fileSystem.read(listed.url)
        #expect(try reader.read(upToCount: 100) == Data("content".utf8))
        reader.close()
        try fileSystem.remove(listed.url)
        #expect(!box.exists("u\u{308}ber.txt"))
    }

    @Test
    internal func aViewerThatReadsOnePageAsksForOnePage() throws {
        let content = Data((0..<4_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try content.write(to: box.url("big.bin"))
        let reader = try fileSystem.read(url("big.bin"))
        // One page, a jump, one page: read correctly, without megabytes fetched ahead that
        // nobody wants (the window only opens for a caller that reads on).
        #expect(try reader.read(upToCount: 4_096) == content.prefix(4_096))
        try reader.seek(to: 3_000_000)
        #expect(try reader.read(upToCount: 4_096) == content.subdata(in: 3_000_000..<3_004_096))
        // Reading on from there gets the rest, through the window.
        var rest = Data()
        while let block = try reader.read(upToCount: 1 << 20) { rest.append(block) }
        #expect(rest == content.suffix(from: 3_004_096))
        reader.close()
    }
}

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
            exec \(systemSFTPServer) -e

            """
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return SFTPTransport(executable: script.path, asksQuestions: true)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: systemSFTPServer)))
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

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: systemSFTPServer)))
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
        // With the right passphrase.value ssh accepts every option it was given and the files are there.
        passphrase.value = "open sesame"
        let working = session()
        defer { working.disconnect() }
        _ = try working.connect(cancellation: nil)
        #expect(try working.entry(at: box.url("srv/hello.txt").path)?.size == 8)
    }
}
