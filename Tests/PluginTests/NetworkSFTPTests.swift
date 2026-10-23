import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The SFTP client against the system's own `sftp-server`, run directly as a child process on
/// a sandbox folder: the same protocol as through `ssh`, without a network or a login.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: LocalSSHServer.systemSFTPServer)))
internal struct NetworkSFTPTests {
    /// The sandbox whose folders the server serves.
    internal let box: Sandbox
    /// The connections, whose sessions talk to `sftp-server` directly.
    internal let center: ConnectionCenter
    /// The file system over the center, as the panels use it.
    internal let fileSystem: RemoteFileSystem
    /// The server; its host name is never looked up.
    internal let key = ServerKey(scheme: "sftp", host: "test.invalid")

    /// A center whose sessions run `sftp-server -e` as their transport.
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
                transport: SFTPTransport(executable: LocalSSHServer.systemSFTPServer, arguments: ["-e"])
            )
        }
        fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
    }

    /// The location of a path inside the sandbox, as the server sees it.
    internal func url(_ path: String) -> URL { key.url(path: box.url(path).path) }

    /// A listing has names, kinds, links, sizes, dates and permissions; hidden names show only when asked, and
    /// a missing folder is an error.
    @Test
    internal func listsAndDescribes() throws {
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        try box.file("a.txt", "hello", modified: stamp)
        try box.file(".hidden", "h")
        try box.file("dir/inner.txt", "i")
        try FileManager.default.createSymbolicLink(at: box.url("to-dir"), withDestinationURL: box.url("dir"))
        try FileManager.default.createSymbolicLink(at: box.url("to-file"), withDestinationURL: box.url("a.txt"))

        let items = try fileSystem.list(url(""), showHidden: false).sorted { $0.name < $1.name }
        #expect(items.map(\.name) == ["a.txt", "dir", "to-dir", "to-file"])
        #expect(
            items.map(\.isDirectory) == [false, true, true, false]
                && items.map(\.isSymlink) == [false, false, true, true]
        )
        #expect(items[0].size == 5 && items[0].modified == stamp && items[0].permissions == 0o644)
        #expect(try fileSystem.list(url(""), showHidden: true).count == 5)
        #expect(fileSystem.item(at: url("dir/inner.txt"))?.size == 1)
        #expect(fileSystem.item(at: url("to-dir"))?.isDirectory == true)
        #expect(fileSystem.item(at: url("nothing")) == nil)
        #expect(throws: (any Error).self) { try fileSystem.list(url("nothing"), showHidden: true) }
        // The start folder is where the server process stands.
        #expect(try center.connect(key).hasPrefix("/"))
        #expect(center.isConnected(key) && fileSystem.places().count == 1)
    }

    /// A large file written in pieces arrives whole with its date and permissions, is not written over, and reads
    /// back from the start or from any offset.
    @Test
    internal func readsWritesAndSeeks() throws {
        let content = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 / 251) })
        let writer = try fileSystem.write(url("big.bin"))
        // In pieces like the copy job's, larger than one round of requests.
        for start in stride(from: 0, to: content.count, by: 300_000) {
            try writer.write(content.subdata(in: start..<min(start + 300_000, content.count)))
        }
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try writer.close(attributes: FileAttributes(modified: stamp, permissions: 0o600))
        #expect(try Data(contentsOf: box.url("big.bin")) == content)
        #expect(
            fileSystem.item(at: url("big.bin"))?.modified == stamp
                && fileSystem.item(at: url("big.bin"))?.permissions == 0o600
        )
        #expect(throws: FileSystemError.self) { _ = try fileSystem.write(url("big.bin")) }

        let reader = try fileSystem.read(url("big.bin"))
        var read = Data()
        while let block = try reader.read(upToCount: 1 << 20) { read.append(block) }
        #expect(read == content)
        try reader.seek(to: 699_990)
        #expect(try reader.read(upToCount: 100) == content.suffix(10))
        #expect(try reader.read(upToCount: 100) == nil)
        try reader.seek(to: 5)
        #expect(try reader.read(upToCount: 7) == content.subdata(in: 5..<12))
        reader.close()
        #expect(throws: (any Error).self) { _ = try fileSystem.read(url("missing.bin")) }
    }

    /// Folders are made with their parents, moves replace only when asked, permissions change, and only empty
    /// folders can be removed.
    @Test
    internal func changes() throws {
        try box.file("a.txt", "a")
        try box.file("b.txt", "b")
        try fileSystem.createDirectory(at: url("x/y/z"))
        #expect(box.exists("x/y/z"))
        try fileSystem.move(url("a.txt"), to: url("x/a.txt"), replacing: false)
        #expect(throws: FileSystemError.self) {
            try fileSystem.move(url("b.txt"), to: url("x/a.txt"), replacing: false)
        }
        try fileSystem.move(url("b.txt"), to: url("x/a.txt"), replacing: true)
        #expect(box.read("x/a.txt") == "b" && !box.exists("b.txt"))
        try fileSystem.setAttributes(FileAttributes(permissions: 0o640), of: url("x/a.txt"))
        #expect(fileSystem.item(at: url("x/a.txt"))?.permissions == 0o640)
        #expect(throws: (any Error).self) { try fileSystem.remove(url("x")) }
        try fileSystem.remove(url("x/a.txt"))
        try fileSystem.remove(url("x/y/z"))
        try fileSystem.remove(url("x/y"))
        try fileSystem.remove(url("x"))
        #expect(!box.exists("x"))
    }

    /// Listings and reads from twelve threads at once share the one connection and each get their own answers.
    @Test
    internal func manyThreadsShareOneChannel() throws {
        for index in 0..<12 { try box.file("d\(index)/f\(index).txt", String(repeating: "x", count: index * 1_000)) }
        let results = Parallel.map(Array(0..<12)) { index -> Int in
            let names = (try? fileSystem.list(url("d\(index)"), showHidden: true).map(\.name)) ?? []
            guard names == ["f\(index).txt"], let reader = try? fileSystem.read(url("d\(index)/f\(index).txt")) else {
                return -1
            }
            defer { reader.close() }
            var count = 0
            while let block = try? reader.read(upToCount: 4_096) { count += block.count }
            return count
        }
        #expect(results == (0..<12).map { $0 * 1_000 })
        #expect(
            fileSystem.totalSize(of: url(""), cancellation: CancellationFlag())
                == Int64((0..<12).reduce(0) { $0 + $1 * 1_000 })
        )
    }

    /// After a disconnect the next listing connects again.
    @Test
    internal func reconnectsAfterDisconnect() throws {
        try box.file("a.txt", "a")
        #expect(try fileSystem.list(url(""), showHidden: true).count == 1)
        center.disconnect(key)
        #expect(!center.isConnected(key) && fileSystem.places().isEmpty)
        #expect(try fileSystem.list(url(""), showHidden: true).count == 1)
    }

    /// A transport that does not speak SFTP fails the connection, which then counts as not connected.
    @Test
    internal func aTransportThatIsNotSFTPFails() throws {
        center.makeSession = { profile, environment in
            SFTPSession(
                profile: profile,
                environment: environment,
                transport: SFTPTransport(executable: "/bin/echo", arguments: ["hello"])
            )
        }
        #expect(throws: (any Error).self) { try fileSystem.list(url(""), showHidden: true) }
        #expect(!center.isConnected(key))
    }

    /// The arguments for `ssh` carry the timeouts, the port and the user, and the host after `--`, lowercased,
    /// so a host name cannot pass as an option.
    @Test
    internal func sshArguments() {
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (20, 45)
        let profile = ConnectionProfile(
            key: ServerKey(scheme: "sftp", host: "-oProxyCommand=evil", port: 2_222),
            user: "deploy"
        )
        let arguments = SFTPSession.sshArguments(for: profile, options: values)
        #expect(arguments.suffix(4) == ["-s", "--", "-oproxycommand=evil", "sftp"])
        #expect(arguments.contains("ConnectTimeout=20") && arguments.contains("ServerAliveInterval=45"))
        #expect(arguments.contains("2222") && arguments.contains("deploy"))
    }

    /// The helper `ssh` calls for its questions, driven here by a shell that calls it the same way.
    @Test
    internal func askpassCarriesQuestionAndAnswer() throws {
        let helper = try AskpassHelper(in: FileManager.default.temporaryDirectory)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\"$SSH_ASKPASS\" \"anna@host's password: \""]
        process.environment = helper.environment
        process.standardOutput = output
        try process.run()
        var question: AskpassHelper.Question?
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while question == nil, Date() < patience {
            question = helper.pendingQuestion()
            if question == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(question?.text == "anna@host's password: " && question?.kind == .entry)
        helper.reply("s3cr\\et $HOME `x`", to: try #require(question))
        process.waitUntilExit()
        let answer = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(answer == "s3cr\\et $HOME `x`\n")
        // Nothing secret is in the environment or in the helper's folder.
        #expect(!helper.environment.values.contains { $0.contains("s3cr") })
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: helper.directory.path).sorted() == [
                "answer", "askpass.sh", "question"
            ]
        )
    }

    /// The whole way through `ssh`: a secure-shell server of the system on 127.0.0.1 with keys
    /// made in the sandbox.
    ///
    /// The host is unknown and the key has a passphrase, so both of ssh's questions come through
    /// the helper. Nothing of the user's own ssh setup is read or written.
    @Test(.enabled(if: LocalSSHServer.isAvailable))
    internal func logsInThroughSSH() throws {
        let server = try LocalSSHServer(box: box, passphrase: "open sesame", banner: nil)
        defer { server.stop() }
        try box.file("srv/hello.txt", "over ssh")
        let transport = SFTPTransport(
            executable: "/usr/bin/ssh",
            arguments: server.clientArguments,
            asksQuestions: true
        )
        center.makeSession = { profile, environment in
            SFTPSession(profile: profile, environment: environment, transport: transport)
        }
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var questions: [(String, Bool)] = []
        let passphrase = Shared("wrong")
        center.environment.declineMemory = 0
        center.environment.askSecret = { _, question, isSecret in
            questions.append((question, isSecret))
            return isSecret ? passphrase.value : "yes"
        }
        // A wrong passphrase: ssh gives up and says why.
        #expect(throws: NetworkError.self) { try fileSystem.list(url("srv"), showHidden: true) }
        #expect(questions.first?.0.contains("(yes/no") == true && questions.first?.1 == false)
        #expect(questions.contains { $0.1 && $0.0.lowercased().contains("passphrase") })

        passphrase.value = "open sesame"
        questions = []
        #expect(try fileSystem.list(url("srv"), showHidden: true).map(\.name) == ["hello.txt"])
        // The host key was accepted the first time and is known now.
        #expect(questions.count == 1 && questions[0].1)
        let reader = try fileSystem.read(url("srv/hello.txt"))
        #expect(try reader.read(upToCount: 100) == Data("over ssh".utf8))
        reader.close()
    }
}
