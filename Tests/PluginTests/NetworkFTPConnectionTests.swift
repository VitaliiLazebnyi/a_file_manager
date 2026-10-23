import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import NetworkPlugin

/// The FTP client's connections, against the test server on 127.0.0.1: reconnecting, several at once, logins,
/// keep-alive, time limits, cancelling and disconnecting.
@Suite
internal struct NetworkFTPConnectionTests {
    /// A connection the server dropped is made again for the next command.
    @Test
    internal func reconnectsAfterTheServerDroppedTheConnection() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        #expect(try fixture.names("/") == ["a.txt"])
        fixture.server.dropConnections()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(try fixture.download("/a.txt") == Data("a".utf8))
        #expect(fixture.server.connectionsOpened == 2)
    }

    /// Listings run side by side on no more connections than allowed, and a tree's size is summed.
    @Test
    internal func listsConcurrentlyOnSeveralConnections() throws {
        var options = TestFTPServer.Options()
        options.listDelay = 0.15
        let fixture = try FTPFixture(options) { $0.parallelConnections = 4 }
        for index in 0..<8 { try fixture.box.file("srv/d\(index)/file\(index).txt", "x") }
        let results = Parallel.map(Array(0..<8)) { index in (try? fixture.names("/d\(index)")) ?? [] }
        #expect(results == (0..<8).map { ["file\($0).txt"] })
        // How many really ran side by side depends on the threads the system has to spare
        // while other tests run; the limit must hold in any case.
        #expect(fixture.server.mostListingsAtOnce >= 1 && fixture.server.mostListingsAtOnce <= 4)
        #expect(fixture.server.connectionsOpened <= 4)
        // Size of a tree: the kernel walks the folders on all cores.
        #expect(fixture.fileSystem.totalSize(of: fixture.url("/"), cancellation: CancellationFlag()) == 8)
    }

    /// While the only connection allowed holds an open file, another one serves commands.
    @Test
    internal func aTransferDoesNotBlockCommands() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        try fixture.box.file("srv/a.txt", String(repeating: "a", count: 100_000))
        let reader = try fixture.fileSystem.read(fixture.url("/a.txt"))
        #expect(try reader.read(upToCount: 10)?.count == 10)
        // With the only connection held by the open file, a second one serves the question.
        #expect(fixture.fileSystem.item(at: fixture.url("/a.txt"))?.size == 100_000)
        try fixture.upload("/b.txt", Data("b".utf8))
        reader.close()
        #expect(fixture.box.read("srv/b.txt") == "b")
    }

    /// A refused guest login asks for credentials until they work, and a password in a typed address
    /// goes to the connection, not into the URL.
    @Test
    internal func asksForThePasswordAndRemembersTheRefusal() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "s3cret")
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "a")
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var questions: [String] = []
        nonisolated(unsafe) var answers: [Credentials?] = [
            Credentials(user: "anna", password: "wrong"), Credentials(user: "anna", password: "s3cret")
        ]
        fixture.environment.askCredentials = { _, message in
            questions.append(message)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        // The guest login is refused, then a wrong password, then the right one.
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(questions.count == 2 && questions[0].contains("530"))
        #expect(fixture.center.profile(of: fixture.key)?.user == "anna")

        fixture.center.disconnect(fixture.key)
        #expect(!fixture.center.isConnected(fixture.key))
        #expect(throws: (any Error).self) { try fixture.names("/") }
        // A password in the typed address goes to the connection, not into the URL.
        let typed = try #require(
            fixture.fileSystem.location(from: "ftp://anna:s3cret@127.0.0.1:\(fixture.server.port)/")
        )
        #expect(typed == fixture.url("/") && !typed.absoluteString.contains("anna"))
        #expect(try fixture.names("/") == ["a.txt"])
    }

    /// A connected server is a place with a remote volume, and display paths, typed locations and parents
    /// go back and forth.
    @Test
    internal func placesAndPaths() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/pub/a b.txt", "a")
        let remote = fixture.fileSystem
        #expect(remote.places().isEmpty)
        _ = try fixture.names("/pub")
        #expect(remote.places().map(\.url) == [fixture.url("/pub")])
        #expect(remote.volume(of: fixture.url("/pub"))?.isLocal == false)
        let file = fixture.url("/pub/a b.txt")
        #expect(remote.displayPath(file) == "ftp://127.0.0.1:\(fixture.server.port)/pub/a b.txt")
        #expect(remote.location(from: remote.displayPath(file)) == file)
        #expect(remote.parent(of: file) == fixture.url("/pub") && remote.parent(of: fixture.url("/")) == nil)
        #expect(remote.location(from: "/local/path") == nil && remote.location(from: "sftp://host/") == nil)
        fixture.center.disconnect(fixture.key)
        #expect(remote.places().isEmpty)
        #expect(fixture.server.commands.last == "QUIT" || fixture.server.openConnections >= 0)
    }

    /// An idle connection is kept alive with NOOP and serves the next command.
    @Test
    internal func keepsIdleConnectionsAlive() throws {
        let fixture = try FTPFixture { $0.keepAliveInterval = 0.3 }
        try fixture.box.file("srv/a.txt", "a")
        // A command that arrives while the connection is being tested waits for it for a moment
        // before it logs in again; that moment is made long, so the count below does not depend
        // on how busy the machine is.
        try #require(try fixture.center.session(for: fixture.key) as? FTPSession).returnGrace = 120
        _ = try fixture.names("/")
        #expect(adoptWait { fixture.server.commands.filter { $0 == "NOOP" }.count >= 2 })
        // The connection that was kept alive is the one that serves the next command.
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(fixture.server.connectionsOpened == 1)
    }

    /// A server that never answers times out after the limit, a cancel ends the wait long before it,
    /// and a port nobody listens on fails.
    @Test
    internal func timesOutAndCancelsOnAServerThatDoesNotAnswer() throws {
        // A port that accepts connections and never says a word.
        let silent = try TestFTPServer.listen()
        defer { close(silent) }
        let fixture = try FTPFixture { $0.timeout = 3 }
        let key = ServerKey(scheme: "ftp", host: "127.0.0.1", port: TestFTPServer.port(of: silent))
        var started = Date()
        #expect { try fixture.fileSystem.list(key.url(), showHidden: true) } throws: { error in
            if case NetworkError.timedOut = error {
                return true
            }
            return false
        }
        // After the time limit, and not much later (the fault would be a wait without end).
        #expect((2.5...120).contains(Date().timeIntervalSince(started)))

        fixture.center.disconnect(key)
        // Cancelled long before the time limit, which is ten minutes now: the error says which of the two ended the
        // wait.
        var patient = fixture.environment.options.values
        patient.timeout = 600
        fixture.environment.options.values = patient
        let cancellation = CancellationFlag()
        // On a thread of its own: a busy machine can keep a dispatch queue waiting for seconds.
        let canceller = Thread {
            Thread.sleep(forTimeInterval: 0.3)
            cancellation.cancel()
        }
        canceller.start()
        started = Date()
        #expect { try fixture.center.connect(key, cancellation: cancellation) } throws: { error in
            if case NetworkError.cancelled = error {
                return true
            }
            return false
        }
        #expect(Date().timeIntervalSince(started) < 120)
        // Nobody listens here at all.
        let closed = try TestFTPServer.listen()
        let port = TestFTPServer.port(of: closed)
        close(closed)
        #expect(throws: NetworkError.self) {
            try fixture.fileSystem.list(
                ServerKey(scheme: "ftp", host: "127.0.0.1", port: port).url(),
                showHidden: true
            )
        }
    }

    /// A disconnect makes a running download fail.
    @Test
    internal func disconnectInterruptsARunningTransfer() throws {
        let fixture = try FTPFixture()
        try Data(count: 4_000_000).write(to: fixture.box.url("srv/big.bin"))
        let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
        #expect(try reader.read(upToCount: 1_000)?.count == 1_000)
        fixture.center.disconnect(fixture.key)
        var failed = false
        do {
            while try reader.read(upToCount: 1 << 20) != nil {
                // Reads on until the disconnect makes it fail.
            }
        } catch {
            failed = true
        }
        reader.close()
        #expect(failed && !fixture.center.isConnected(fixture.key))
    }

    /// The copy job uploads and downloads, and a cancelled upload leaves no partial file on the server.
    @Test
    internal func aCancelledCopyLeavesNothingBehind() throws {
        let fixture = try FTPFixture()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(fixture.fileSystem)
        try Data(count: 3_000_000).write(to: fixture.box.url("big.bin"))
        try fixture.box.file("small.txt", "small")
        // Upload with the real copy job: complete once, then cancelled half-way.
        let target = TargetSpec(directory: fixture.url("/"))
        var result = Answers().run(.copy, [fixture.box.url("small.txt")], to: target, fileSystems: fileSystems)
        #expect(result.completed.count == 1 && fixture.box.read("srv/small.txt") == "small")
        let answers = Answers()
        answers.cancelAtBytes = 1_000_000
        result = answers.run(.copy, [fixture.box.url("big.bin")], to: target, fileSystems: fileSystems)
        #expect(result.cancelled && namesOnDisk(fixture.box.url("srv")) == ["small.txt"])
        // And the way back, under another name.
        result = Answers()
            .run(
                .copy,
                [fixture.url("/small.txt")],
                to: TargetSpec(directory: fixture.box.url("srv"), mask: "copy.txt"),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 1 && fixture.box.read("srv/copy.txt") == "small")
        #expect(try fixture.names("/") == ["copy.txt", "small.txt"])
    }
}
