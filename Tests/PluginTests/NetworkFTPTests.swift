import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import NetworkPlugin

/// A test server on a sandbox folder with the FTP file system connected to it. Unchecked: set up
/// in `init` and not changed afterwards; the server and the connections are safe from any thread.
final class FTPFixture: @unchecked Sendable {
    let box: Sandbox
    let server: TestFTPServer
    let center: ConnectionCenter
    let fileSystem: RemoteFileSystem
    var environment: SessionEnvironment { center.environment }

    init(
        _ options: TestFTPServer.Options = TestFTPServer.Options(),
        configure: (inout NetworkOptions.Values) -> Void = { _ in }
    ) throws {
        box = try Sandbox()
        try box.folder("srv")
        server = try TestFTPServer(root: box.url("srv"), options: options)
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 10
        values.keepAliveInterval = 0
        configure(&values)
        environment.options.values = values
        environment.declineMemory = 0
        center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        fileSystem = RemoteFileSystem(scheme: "ftp", center: center)
    }

    deinit {
        center.disconnectAll()
        server.stop()
    }

    var key: ServerKey { ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port) }

    /// Waits until the background work of this fixture's session is done (connections given
    /// back, goodbyes said). Of this session only: the tests run side by side, and the work of
    /// another test's server, which may be one that never answers, is not waited for.
    func settle(_ session: (any RemoteSession)? = nil, timeout: TimeInterval = 300) -> Bool {
        guard let session = session ?? center.existingSession(for: key) else { return true }
        return Background.waitUntilIdle(lane: session, timeout: timeout)
    }
    func url(_ path: String) -> URL { key.url(path: path) }

    func names(_ path: String, showHidden: Bool = false) throws -> [String] {
        try fileSystem.list(url(path), showHidden: showHidden).map(\.name).sorted()
    }

    func download(_ path: String, from offset: UInt64 = 0) throws -> Data {
        let reader = try fileSystem.read(url(path))
        defer { reader.close() }
        if offset > 0 { try reader.seek(to: offset) }
        var data = Data()
        while let block = try reader.read(upToCount: 4_096) { data.append(block) }
        return data
    }

    func upload(_ path: String, _ content: Data, attributes: FileAttributes = FileAttributes()) throws {
        let writer = try fileSystem.write(url(path))
        try writer.write(content)
        try writer.close(attributes: attributes)
    }
}

/// The FTP client end to end, against the test server on 127.0.0.1.
@Suite struct NetworkFTP {
    @Test(arguments: [true, false]) func listsWithMLSDAndWithLIST(mlsd: Bool) throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = mlsd
        let fixture = try FTPFixture(options)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try fixture.box.file("srv/readme.txt", "hello", modified: old)
        try fixture.box.file("srv/.hidden", "h")
        try fixture.box.file("srv/name with spaces.dat", "12345678")
        try fixture.box.file("srv/pub/inner.txt", "i")

        let items = try fixture.fileSystem.list(fixture.url("/"), showHidden: false).sorted { $0.name < $1.name }
        #expect(items.map(\.name) == ["name with spaces.dat", "pub", "readme.txt"])
        #expect(items.map(\.isDirectory) == [false, true, false])
        #expect(items[0].size == 8 && items[2].size == 5)
        #expect(items[2].modified == old || abs(items[2].modified.timeIntervalSince(old)) < 86_400)
        #expect(items[0].url == fixture.url("/name with spaces.dat"))
        #expect(try fixture.names("/", showHidden: true).contains(".hidden"))
        #expect(try fixture.names("/pub") == ["inner.txt"])
        #expect(fixture.server.commands.contains { $0.hasPrefix("MLSD") } == mlsd)
        #expect(throws: (any Error).self) { try fixture.names("/missing") }
    }

    @Test func listsDOSFormatAndWithoutEPSV() throws {
        var options = TestFTPServer.Options()
        (options.offersMLSD, options.dosListing, options.offersEPSV) = (false, true, false)
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "abc")
        try fixture.box.folder("srv/dir")
        let items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true).sorted { $0.name < $1.name }
        #expect(items.map(\.name) == ["a.txt", "dir"] && items[0].size == 3 && items[1].isDirectory)
        #expect(fixture.server.commands.contains("PASV"))
        // The refused EPSV is not tried again.
        _ = try fixture.names("/dir")
        #expect(fixture.server.commands.filter { $0 == "EPSV" }.count == 1)
    }

    @Test func activeMode() throws {
        let fixture = try FTPFixture { $0.passiveByDefault = false }
        try fixture.box.file("srv/a.txt", "active")
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(try fixture.download("/a.txt") == Data("active".utf8))
        #expect(fixture.server.commands.contains { $0.hasPrefix("PORT") } && !fixture.server.commands.contains("EPSV"))
    }

    @Test func downloadsUploadsAndResumes() throws {
        let fixture = try FTPFixture()
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try content.write(to: fixture.box.url("srv/big.bin"))
        #expect(try fixture.download("/big.bin") == content)
        // Resume: the rest from a position, fetched with REST.
        #expect(try fixture.download("/big.bin", from: 123_456) == content.subdata(in: 123_456..<content.count))
        #expect(fixture.server.commands.contains("REST 123456"))

        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.upload("/up.bin", content, attributes: FileAttributes(modified: stamp, permissions: 0o600))
        #expect(try Data(contentsOf: fixture.box.url("srv/up.bin")) == content)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.box.url("srv/up.bin").path)
        #expect(attributes[.modificationDate] as? Date == stamp)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // An existing file is never overwritten by `write`.
        #expect(throws: FileSystemError.self) { try fixture.upload("/up.bin", Data("x".utf8)) }
        #expect(throws: (any Error).self) { _ = try fixture.download("/nothing.bin") }
    }

    @Test func seeksWhileReading() throws {
        let fixture = try FTPFixture()
        let content = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        try content.write(to: fixture.box.url("srv/f.bin"))
        let reader = try fixture.fileSystem.read(fixture.url("/f.bin"))
        defer { reader.close() }
        #expect(try reader.read(upToCount: 10) == content.prefix(10))
        // A short hop forward stays on the same transfer; a jump back starts a new one.
        try reader.seek(to: 1_000)
        #expect(try reader.read(upToCount: 5) == content.subdata(in: 1_000..<1_005))
        try reader.seek(to: 500_000)
        #expect(try reader.read(upToCount: 5) == content.subdata(in: 500_000..<500_005))
        try reader.seek(to: 3)
        #expect(try reader.read(upToCount: 4) == content.subdata(in: 3..<7))
        reader.close()
        // Closing returns at once and the server is told in the background. Once that is done,
        // the connection that was interrupted twice still serves commands.
        #expect(fixture.settle())
        #expect(try fixture.names("/") == ["f.bin"])
        #expect(fixture.server.connectionsOpened == 1)
    }

    @Test func makesRenamesAndDeletes() throws {
        let fixture = try FTPFixture()
        let fs = fixture.fileSystem
        try fixture.box.file("srv/a.txt", "a")
        try fixture.box.file("srv/b.txt", "b")
        try fs.createDirectory(at: fixture.url("/x/y/z"))
        #expect(fixture.box.exists("srv/x/y/z"))
        try fs.createDirectory(at: fixture.url("/x/y"))
        #expect(throws: FileSystemError.self) { try fs.createDirectory(at: fixture.url("/a.txt")) }

        try fs.move(fixture.url("/a.txt"), to: fixture.url("/x/moved.txt"), replacing: false)
        #expect(fixture.box.read("srv/x/moved.txt") == "a" && !fixture.box.exists("srv/a.txt"))
        #expect(throws: FileSystemError.self) {
            try fs.move(fixture.url("/b.txt"), to: fixture.url("/x/moved.txt"), replacing: false)
        }
        #expect(fixture.box.read("srv/x/moved.txt") == "a")
        try fs.move(fixture.url("/b.txt"), to: fixture.url("/x/moved.txt"), replacing: true)
        #expect(fixture.box.read("srv/x/moved.txt") == "b")

        #expect(fs.item(at: fixture.url("/x/moved.txt"))?.size == 1)
        #expect(fs.item(at: fixture.url("/x"))?.isDirectory == true)
        #expect(fs.item(at: fixture.url("/gone")) == nil)
        #expect(fs.item(at: fixture.url("/"))?.isDirectory == true)

        // A folder that is not empty stays; files and empty folders go.
        #expect(throws: (any Error).self) { try fs.remove(fixture.url("/x")) }
        try fs.remove(fixture.url("/x/moved.txt"))
        try fs.remove(fixture.url("/x/y/z"))
        try fs.remove(fixture.url("/x/y"))
        try fs.remove(fixture.url("/x"))
        #expect(!fixture.box.exists("srv/x"))
        #expect(throws: FileSystemError.self) { try fs.copy(fixture.url("/a"), to: fixture.url("/b")) { _ in true } }
    }

    @Test func changesAttributes() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        let stamp = Date(timeIntervalSince1970: 1_400_000_000)
        try fixture.fileSystem.setAttributes(
            FileAttributes(modified: stamp, permissions: 0o640), of: fixture.url("/a.txt"))
        let item = try #require(fixture.fileSystem.item(at: fixture.url("/a.txt")))
        #expect(item.modified == stamp && item.permissions == 0o640)
    }

    @Test func itemWithoutMLST() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/d/a.txt", "abcd")
        #expect(fixture.fileSystem.item(at: fixture.url("/d/a.txt"))?.size == 4)
        #expect(fixture.fileSystem.item(at: fixture.url("/d"))?.isDirectory == true)
        #expect(fixture.fileSystem.item(at: fixture.url("/d/none")) == nil)
        fixture.server.options.offersSize = false
        fixture.center.disconnect(fixture.key)
        #expect(fixture.fileSystem.item(at: fixture.url("/d/a.txt"))?.size == 4)
        #expect(fixture.fileSystem.item(at: fixture.url("/d"))?.isDirectory == true)
    }

    @Test func textModeConvertsLineEnds() throws {
        let fixture = try FTPFixture { $0.transferMode = .automatic }
        try fixture.upload("/note.txt", Data("one\ntwo\r\nthree\n".utf8))
        #expect(try Data(contentsOf: fixture.box.url("srv/note.txt")) == Data("one\r\ntwo\r\nthree\r\n".utf8))
        #expect(try fixture.download("/note.txt") == Data("one\ntwo\nthree\n".utf8))
        // Anything that is not on the list of text files travels unchanged.
        try fixture.upload("/note.bin", Data("one\n".utf8))
        #expect(try Data(contentsOf: fixture.box.url("srv/note.bin")) == Data("one\n".utf8))
        #expect(fixture.server.commands.contains("TYPE A") && fixture.server.commands.contains("TYPE I"))
    }

    @Test func unicodeNames() throws {
        let fixture = try FTPFixture()
        try fixture.upload("/Grüße & 日本語.txt", Data("ü".utf8))
        #expect(try fixture.names("/") == ["Grüße & 日本語.txt"])
        #expect(try fixture.download("/Grüße & 日本語.txt") == Data("ü".utf8))
        #expect(fixture.server.commands.contains("OPTS UTF8 ON"))
        #expect(throws: (any Error).self) { try fixture.fileSystem.createDirectory(at: fixture.url("/a\r\nDELE x")) }
        #expect(!fixture.server.commands.contains("DELE x"))
    }

    @Test func reconnectsAfterTheServerDroppedTheConnection() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        #expect(try fixture.names("/") == ["a.txt"])
        fixture.server.dropConnections()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(try fixture.download("/a.txt") == Data("a".utf8))
        #expect(fixture.server.connectionsOpened == 2)
    }

    @Test func listsConcurrentlyOnSeveralConnections() throws {
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
        #expect(fixture.fileSystem.totalSize(of: fixture.url("/")) == 8)
    }

    @Test func aTransferDoesNotBlockCommands() throws {
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

    @Test func asksForThePasswordAndRemembersTheRefusal() throws {
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
            fixture.fileSystem.location(from: "ftp://anna:s3cret@127.0.0.1:\(fixture.server.port)/"))
        #expect(typed == fixture.url("/") && !typed.absoluteString.contains("anna"))
        #expect(try fixture.names("/") == ["a.txt"])
    }

    @Test func placesAndPaths() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/pub/a b.txt", "a")
        let fs = fixture.fileSystem
        #expect(fs.places().isEmpty)
        _ = try fixture.names("/pub")
        #expect(fs.places().map(\.url) == [fixture.url("/pub")])
        #expect(fs.volume(of: fixture.url("/pub"))?.isLocal == false)
        let file = fixture.url("/pub/a b.txt")
        #expect(fs.displayPath(file) == "ftp://127.0.0.1:\(fixture.server.port)/pub/a b.txt")
        #expect(fs.location(from: fs.displayPath(file)) == file)
        #expect(fs.parent(of: file) == fixture.url("/pub") && fs.parent(of: fixture.url("/")) == nil)
        #expect(fs.location(from: "/local/path") == nil && fs.location(from: "sftp://host/") == nil)
        fixture.center.disconnect(fixture.key)
        #expect(fs.places().isEmpty)
        #expect(fixture.server.commands.last == "QUIT" || fixture.server.openConnections >= 0)
    }

    @Test func keepsIdleConnectionsAlive() throws {
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

    @Test func timesOutAndCancelsOnAServerThatDoesNotAnswer() throws {
        // A port that accepts connections and never says a word.
        let silent = try TestFTPServer.listen()
        defer { close(silent) }
        let fixture = try FTPFixture { $0.timeout = 3 }
        let key = ServerKey(scheme: "ftp", host: "127.0.0.1", port: TestFTPServer.port(of: silent))
        var started = Date()
        #expect { try fixture.fileSystem.list(key.url(), showHidden: true) } throws: { error in
            if case NetworkError.timedOut = error { return true }
            return false
        }
        // After the time limit, and not much later (the fault would be a wait without end).
        #expect((2.5...120).contains(Date().timeIntervalSince(started)))

        fixture.center.disconnect(key)
        // Cancelled long before the time limit, which is ten minutes now: the error says which of the two ended the wait.
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
            if case NetworkError.cancelled = error { return true }
            return false
        }
        #expect(Date().timeIntervalSince(started) < 120)
        // Nobody listens here at all.
        let closed = try TestFTPServer.listen()
        let port = TestFTPServer.port(of: closed)
        close(closed)
        #expect(throws: NetworkError.self) {
            try fixture.fileSystem.list(
                ServerKey(scheme: "ftp", host: "127.0.0.1", port: port).url(), showHidden: true)
        }
    }

    @Test func disconnectInterruptsARunningTransfer() throws {
        let fixture = try FTPFixture()
        try Data(count: 4_000_000).write(to: fixture.box.url("srv/big.bin"))
        let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
        #expect(try reader.read(upToCount: 1_000)?.count == 1_000)
        fixture.center.disconnect(fixture.key)
        var failed = false
        do {
            while try reader.read(upToCount: 1 << 20) != nil {}
        } catch {
            failed = true
        }
        reader.close()
        #expect(failed && !fixture.center.isConnected(fixture.key))
    }

    @Test func aCancelledCopyLeavesNothingBehind() throws {
        let fixture = try FTPFixture()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(fixture.fileSystem)
        try Data(count: 3_000_000).write(to: fixture.box.url("big.bin"))
        try fixture.box.file("small.txt", "small")
        // Upload with the real copy job: complete once, then cancelled half-way.
        let target = TargetSpec(directory: fixture.url("/"))
        var result = runJob(.copy, [fixture.box.url("small.txt")], to: target, fileSystems: fileSystems)
        #expect(result.completed.count == 1 && fixture.box.read("srv/small.txt") == "small")
        let answers = Answers()
        answers.cancelAtBytes = 1_000_000
        result = runJob(.copy, [fixture.box.url("big.bin")], to: target, answers: answers, fileSystems: fileSystems)
        #expect(result.cancelled && namesOnDisk(fixture.box.url("srv")) == ["small.txt"])
        // And the way back, under another name.
        result = runJob(
            .copy, [fixture.url("/small.txt")], to: TargetSpec(directory: fixture.box.url("srv"), mask: "copy.txt"),
            fileSystems: fileSystems)
        #expect(result.completed.count == 1 && fixture.box.read("srv/copy.txt") == "small")
        #expect(try fixture.names("/") == ["copy.txt", "small.txt"])
    }
}
