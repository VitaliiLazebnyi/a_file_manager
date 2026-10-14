import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// A call made on a thread of its own, so that one which does not come back fails the test
/// instead of hanging it. (Threads rather than `DispatchQueue.global()`, which stalls for
/// seconds while the whole suite runs.)
final class AdoptOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var error: (any Error)?
    private var finished = false

    init(_ work: @escaping @Sendable () throws -> Void) {
        Thread { [self] in
            do { try work() } catch {
                lock.lock()
                self.error = error
                lock.unlock()
            }
            lock.lock()
            finished = true
            lock.unlock()
            done.signal()
        }
        .start()
    }

    /// True when the call ended within `seconds`. The default is long on purpose: these tests
    /// run beside many others, and what they show is that a call ends at all where the fault
    /// would be a wait of ten minutes or for ever, not how fast it ends.
    func ended(within seconds: TimeInterval = 120) -> Bool { done.wait(timeout: .now() + seconds) == .success }
    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished && error != nil
    }
}

func adoptWait(_ seconds: TimeInterval = 120, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    return condition()
}

/// Sets the flag from a thread of its own after a moment.
func adoptCancel(_ flag: CancellationFlag, after delay: TimeInterval = 0.3) {
    Thread {
        Thread.sleep(forTimeInterval: delay)
        flag.cancel()
    }
    .start()
}

/// Cancelling, appending, per-location capabilities and links, against the FTP test server.
@Suite struct NetworkAdoptFTP {
    private func connectionCount(_ fixture: FTPFixture) throws -> Int {
        try #require(try fixture.center.session(for: fixture.key) as? FTPSession).connectionCount
    }

    @Test(arguments: [true, false]) func aCancelledListingEndsAtOnceAndGivesTheConnectionUp(streaming: Bool) throws {
        var options = TestFTPServer.Options()
        options.listDelay = 600
        let fixture = try FTPFixture(options) { $0.timeout = 600 }
        let flag = CancellationFlag()
        let outcome = AdoptOutcome {
            if streaming {
                try fixture.fileSystem.list(fixture.url("/"), showHidden: false, cancellation: flag) { _ in true }
            } else {
                _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: false, cancellation: flag)
            }
        }
        #expect(adoptWait { fixture.server.commands.contains { $0.hasPrefix("MLSD") || $0.hasPrefix("LIST") } })
        let started = Date()
        adoptCancel(flag)
        #expect(outcome.ended())
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.failed)
        // The connection that was in the middle of the listing is not used again.
        #expect(try connectionCount(fixture) == 0)
        // Nothing is left in a bad state: the next listing works.
        fixture.server.options.listDelay = 0
        _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: false)
    }

    @Test func aFlagThatIsSetAlreadyStopsEverythingBeforeItStarts() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/f.txt", "x")
        let flag = CancellationFlag()
        flag.cancel()
        #expect(fixture.fileSystem.item(at: fixture.url("/f.txt"), cancellation: flag) == nil)
        #expect(throws: (any Error).self) {
            _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: false, cancellation: flag)
        }
        #expect(throws: (any Error).self) {
            _ = try fixture.fileSystem.read(fixture.url("/f.txt"), cancellation: flag)
        }
        #expect(throws: (any Error).self) {
            _ = try fixture.fileSystem.write(fixture.url("/g.txt"), cancellation: flag)
        }
        #expect(!fixture.box.exists("srv/g.txt"))
    }

    @Test func aCancelledListingIsNotRemembered() throws {
        var options = TestFTPServer.Options()
        options.listDelay = 600
        let fixture = try FTPFixture(options) { $0.timeout = 600 }
        try fixture.box.file("srv/f.txt", "x")
        let flag = CancellationFlag()
        let outcome = AdoptOutcome {
            _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: true, cancellation: flag)
        }
        #expect(adoptWait { fixture.server.commands.contains { $0.hasPrefix("MLSD") } })
        adoptCancel(flag)
        #expect(outcome.ended())
        fixture.server.options.listDelay = 0
        try fixture.box.file("srv/g.txt", "y")
        #expect(fixture.fileSystem.item(at: fixture.url("/g.txt"))?.size == 1)
    }

    @Test func interruptingAReaderEndsAReadThatWaitsForTheServer() throws {
        let fixture = try FTPFixture { $0.timeout = 600 }
        try fixture.box.file("srv/f.bin", String(repeating: "z", count: 1_000))
        fixture.server.options.stallRETR = true
        let flag = CancellationFlag()
        let reader = try fixture.fileSystem.read(fixture.url("/f.bin"), cancellation: flag)
        let token = flag.interrupting(reader)
        let outcome = AdoptOutcome { _ = try reader.read(upToCount: 100) }
        #expect(adoptWait { fixture.server.commands.contains { $0.hasPrefix("RETR") } })
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        adoptCancel(flag, after: 0)
        #expect(outcome.ended())
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.failed)
        // Every later call fails too, and closing from the owner's thread is quick.
        #expect(throws: (any Error).self) { _ = try reader.read(upToCount: 1) }
        #expect(throws: (any Error).self) { try reader.seek(to: 10) }
        reader.close()
        #expect(try connectionCount(fixture) == 0)
        withExtendedLifetime(token) {}
        // Interrupting again, or after the end, does nothing.
        reader.interrupt()
    }

    @Test func aReaderInterruptedBeforeItsFirstReadNeverStarts() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/f.bin", "abc")
        let reader = try fixture.fileSystem.read(fixture.url("/f.bin"))
        reader.interrupt()
        #expect(throws: (any Error).self) { _ = try reader.read(upToCount: 10) }
        reader.close()
        #expect(!fixture.server.commands.contains { $0.hasPrefix("RETR") })
    }

    @Test func interruptingAWriterEndsAWriteThatWaitsForTheServer() throws {
        var options = TestFTPServer.Options()
        options.stallSTOR = true
        let fixture = try FTPFixture(options) { $0.timeout = 600 }
        let flag = CancellationFlag()
        let writer = try fixture.fileSystem.write(fixture.url("/up.bin"), cancellation: flag)
        let token = flag.interrupting(writer)
        // The server reads nothing, so the socket buffers fill up and a write blocks.
        let outcome = AdoptOutcome {
            let block = Data(count: 1 << 20)
            for _ in 0..<2_000 { try writer.write(block) }
        }
        #expect(adoptWait { fixture.server.commands.contains { $0.hasPrefix("STOR") } })
        Thread.sleep(forTimeInterval: 1)
        let started = Date()
        adoptCancel(flag, after: 0)
        #expect(outcome.ended())
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.failed)
        #expect(throws: (any Error).self) { try writer.write(Data(count: 10)) }
        #expect(throws: (any Error).self) { try writer.close(attributes: FileAttributes()) }
        #expect(try connectionCount(fixture) == 0)
        withExtendedLifetime(token) {}
        writer.interrupt()
    }

    // MARK: Continuing a file

    @Test func continuesAFileInTheMiddleAtTheEndAndWhereItEnds() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/f.bin", "0123456789")
        let fs = fixture.fileSystem
        let url = fixture.url("/f.bin")
        #expect(fs.capabilities.contains(.append) && fs.capabilities(for: url).contains(.append))
        #expect(fs.item(at: url)?.size == 10)

        // Cut to four bytes, then the rest of the new content follows.
        var writer = try fs.append(to: url, at: 4, cancellation: CancellationFlag())
        try writer.write(Data("abcdef".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(fixture.box.read("srv/f.bin") == "0123abcdef")
        #expect(fs.item(at: url)?.size == 10)
        #expect(fixture.server.commands.contains("REST 4") && fixture.server.commands.contains("STOR /f.bin"))

        // Without an offset it goes on at the end.
        writer = try fs.append(to: url, at: nil, cancellation: CancellationFlag())
        try writer.write(Data("XY".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(fixture.box.read("srv/f.bin") == "0123abcdefXY")
        #expect(fs.item(at: url)?.size == 12)
        #expect(fixture.server.commands.contains("APPE /f.bin"))

        // An offset that is the length takes the same way, without REST.
        let restsBefore = fixture.server.commands.filter { $0.hasPrefix("REST") }.count
        writer = try fs.append(to: url, at: 12, cancellation: CancellationFlag())
        try writer.write(Data("Z".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(fixture.box.read("srv/f.bin") == "0123abcdefXYZ")
        #expect(fixture.server.commands.filter { $0.hasPrefix("REST") }.count == restsBefore)
        #expect(fs.item(at: url)?.size == 13)

        // A file that is shorter than the offset, and one that is not there, are errors.
        #expect(throws: (any Error).self) { _ = try fs.append(to: url, at: 99, cancellation: CancellationFlag()) }
        #expect(throws: (any Error).self) {
            _ = try fs.append(to: fixture.url("/none.bin"), at: nil, cancellation: CancellationFlag())
        }
        #expect(fixture.box.read("srv/f.bin") == "0123abcdefXYZ")
    }

    @Test func aServerThatKeepsTheTailIsReportedNotTrusted() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/f.bin", "0123456789")
        // The new content is shorter than what lay behind the offset, and FTP cannot cut a file.
        let writer = try fixture.fileSystem.append(to: fixture.url("/f.bin"), at: 4, cancellation: CancellationFlag())
        try writer.write(Data("abc".utf8))
        #expect(throws: (any Error).self) { try writer.close(attributes: FileAttributes()) }
    }

    @Test func withoutRESTAndInTextModeTheCapabilityIsMissing() throws {
        var options = TestFTPServer.Options()
        options.offersREST = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/f.bin", "0123456789")
        let url = fixture.url("/f.bin")
        // Before the first login nothing is known and the provider's answer stands.
        #expect(fixture.fileSystem.capabilities(for: url).contains(.append))
        _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: false)
        #expect(!fixture.fileSystem.capabilities(for: url).contains(.append))
        #expect(fixture.fileSystem.capabilities(for: url).contains(.write))
        #expect(throws: FileSystemError.self) {
            _ = try fixture.fileSystem.append(to: url, at: 4, cancellation: CancellationFlag())
        }
        #expect(fixture.box.read("srv/f.bin") == "0123456789")

        let text = try FTPFixture { $0.transferMode = .text }
        _ = try text.fileSystem.list(text.url("/"), showHidden: false)
        #expect(!text.fileSystem.capabilities(for: text.url("/f.txt")).contains(.append))
        #expect(throws: FileSystemError.self) {
            _ = try text.fileSystem.append(to: text.url("/f.txt"), at: nil, cancellation: CancellationFlag())
        }
        // Another scheme's location is not this provider's business.
        #expect(text.fileSystem.capabilities(for: URL(fileURLWithPath: "/tmp")) == text.fileSystem.capabilities)
    }

    // MARK: Links and TLS

    @Test func linksBeyondTheProbeLimitAreResolvedAfterTheListing() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/d")
        for index in 0..<40 {
            try FileManager.default.createSymbolicLink(
                at: fixture.box.url("srv/link\(index)"),
                withDestinationURL: fixture.box.url("srv/d")
            )
        }
        let first = try fixture.fileSystem.list(fixture.url("/"), showHidden: false).filter(\.isSymlink)
        #expect(first.count == 40)
        // Only some could be asked within the limit...
        #expect(first.filter(\.isDirectory).count < 40)
        // ... the rest follows in the background, and the next listing knows.
        func allResolved() -> Bool {
            let links = (try? fixture.fileSystem.list(fixture.url("/"), showHidden: false))?.filter(\.isSymlink) ?? []
            return links.count == 40 && links.allSatisfy(\.isDirectory)
        }
        #expect(adoptWait(20, until: allResolved))
    }

    @Test func aLinkResolvedInTheBackgroundIsAFolderInWhatTheFileSystemRemembers() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/d")
        for index in 0..<40 {
            try FileManager.default.createSymbolicLink(
                at: fixture.box.url("srv/link\(index)"),
                withDestinationURL: fixture.box.url("srv/d")
            )
        }
        // The listing is remembered by the file system, with some links not resolved yet.
        let stored = Date()
        let listed = try fixture.fileSystem.list(fixture.url("/"), showHidden: false).filter(\.isSymlink)
        #expect(listed.count == 40 && listed.filter(\.isDirectory).count < 40)
        // The server has been asked about every link once the background work is through. That
        // work gives up after a while (20 s); on a machine so busy that it did, there is nothing to check.
        func asked() -> Int { Set(fixture.server.commands.filter { $0.hasPrefix("CWD /link") }).count }
        guard adoptWait(40, until: { asked() == 40 }) else {
            try Test.cancel("the background work did not get through in time")
        }
        // A moment later the remembered entries say so, too. After the lifetime of a remembered
        // listing the file system asks the server again, which would prove nothing about them.
        func allFolders() -> Bool {
            (0..<40).allSatisfy { fixture.fileSystem.item(at: fixture.url("/link\($0)"))?.isDirectory == true }
        }
        let patched = adoptWait(max(0, 8 - Date().timeIntervalSince(stored)), until: allFolders)
        if Date().timeIntervalSince(stored) < 9 { #expect(patched) }
    }

    @Test func aServerThatWantsTheTLSSessionReusedGetsAnUnderstandableError() {
        func reply(_ code: Int, _ text: String) -> FTPReply { FTPReply(code: code, lines: [text]) }
        #expect(FTPConnection.requiresSessionReuse(reply(522, "SSL connection failed; session reuse required")))
        #expect(FTPConnection.requiresSessionReuse(reply(522, "Data connection must use cached TLS session")))
        #expect(
            FTPConnection.requiresSessionReuse(
                reply(425, "Unable to build data connection: TLS session of data connection not resumed.")
            )
        )
        #expect(FTPConnection.requiresSessionReuse(reply(421, "TLS session reuse required")))
        #expect(!FTPConnection.requiresSessionReuse(reply(425, "Can't open data connection")))
        #expect(!FTPConnection.requiresSessionReuse(reply(550, "No such file")))
        #expect(!FTPConnection.requiresSessionReuse(reply(226, "session reuse")))
        let message = NetworkError.sessionReuseRequired("522 session reuse required").errorDescription ?? ""
        #expect(message.contains("reuse") && message.contains("522 session reuse required"))
        #expect(!NetworkError.sessionReuseRequired("x").isConnectionLevel)
    }
}

/// Cancelling against the SFTP test server that stops answering, while other transfers share the channel.
@Suite(.enabled(if: FakeSFTPServer.isAvailable)) struct NetworkAdoptSFTP {
    @Test func aCancelledListingEndsAndTheChannelStaysOpen() throws {
        let suite = try NetworkFixSFTP(mode: .hangingIO, timeout: 600)
        try NetworkFixSFTP.pattern(1_000).write(to: suite.box.url("srv/f.bin"))
        let flag = CancellationFlag()
        let outcome = AdoptOutcome {
            _ = try suite.fileSystem.list(suite.url("/"), showHidden: false, cancellation: flag)
        }
        Thread.sleep(forTimeInterval: 0.6)
        let started = Date()
        adoptCancel(flag, after: 0)
        #expect(outcome.ended())
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.failed)
        let session = try suite.center.session(for: suite.key)
        #expect(session.isConnected)
        #expect(try session.entry(at: "/f.bin")?.size == 1_000)

        // A question that is never answered ends with the flag as well.
        let second = CancellationFlag()
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var found: FileItem? = FileItem(url: suite.url("/x"), name: "x")
        let asking = AdoptOutcome { found = suite.fileSystem.item(at: suite.url("/hang"), cancellation: second) }
        Thread.sleep(forTimeInterval: 0.3)
        adoptCancel(second, after: 0)
        #expect(asking.ended())
        #expect(found == nil)
    }

    @Test func interruptingOneReaderLeavesTheOtherTransfersAlone() throws {
        let suite = try NetworkFixSFTP(mode: .hangingIO, timeout: 600)
        try NetworkFixSFTP.pattern(500_000).write(to: suite.box.url("srv/a.bin"))
        let other = NetworkFixSFTP.pattern(50_000)
        try other.write(to: suite.box.url("srv/b.bin"))
        let flag = CancellationFlag()
        let stuck = try suite.fileSystem.read(suite.url("/a.bin"), cancellation: flag)
        let token = flag.interrupting(stuck)
        let bystander = try suite.fileSystem.read(suite.url("/b.bin"))
        #expect(try bystander.read(upToCount: 1_000) == other.prefix(1_000))

        // Reads past 98304 are never answered.
        let outcome = AdoptOutcome { while try stuck.read(upToCount: 1 << 20) != nil {} }
        Thread.sleep(forTimeInterval: 0.8)
        let started = Date()
        adoptCancel(flag, after: 0)
        #expect(outcome.ended())
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.failed)
        #expect(throws: (any Error).self) { _ = try stuck.read(upToCount: 10) }
        #expect(throws: (any Error).self) { try stuck.seek(to: 5) }
        stuck.close()

        // The channel is open and the other transfer goes on.
        let session = try suite.center.session(for: suite.key)
        #expect(session.isConnected)
        var rest = other.prefix(1_000)
        while let block = try bystander.read(upToCount: 1 << 20) { rest.append(block) }
        #expect(rest == other)
        bystander.close()
        #expect(try session.entry(at: "/b.bin")?.size == 50_000)
        withExtendedLifetime(token) {}
    }

    @Test func interruptingAWriterEndsAWriteWhoseAnswersNeverCome() throws {
        let suite = try NetworkFixSFTP(mode: .hangingIO, timeout: 600)
        let other = NetworkFixSFTP.pattern(50_000)
        try other.write(to: suite.box.url("srv/b.bin"))
        let flag = CancellationFlag()
        let writer = try suite.fileSystem.write(suite.url("/w.bin"), cancellation: flag)
        let token = flag.interrupting(writer)
        // More than a window of requests, none of them answered.
        let outcome = AdoptOutcome {
            let block = Data(count: 1 << 20)
            for _ in 0..<8 { try writer.write(block) }
        }
        Thread.sleep(forTimeInterval: 0.8)
        let started = Date()
        adoptCancel(flag, after: 0)
        #expect(outcome.ended())
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.failed)
        #expect(throws: (any Error).self) { try writer.write(Data(count: 10)) }
        #expect(throws: (any Error).self) { try writer.close(attributes: FileAttributes()) }
        let session = try suite.center.session(for: suite.key)
        #expect(session.isConnected)
        let reader = try suite.fileSystem.read(suite.url("/b.bin"))
        var read = Data()
        while let block = try reader.read(upToCount: 1 << 20) { read.append(block) }
        #expect(read == other)
        reader.close()
        withExtendedLifetime(token) {}
    }

    @Test func aSendThatIsCancelledOnAFullPipeEnds() throws {
        let box = try Sandbox()
        let server = try FakeSFTPServer(root: box.url("."), box: box, mode: .stalled)
        let channel = SFTPChannel(
            executable: server.transport.executable,
            arguments: server.transport.arguments,
            environment: [:],
            writeTimeout: 600
        )
        try channel.start(timeout: 10, cancellation: nil) { true }
        defer { channel.close() }
        let flag = CancellationFlag()
        // Nobody reads the pipe: the packet gets stuck half way and the writer must not wait the full minute.
        let outcome = AdoptOutcome {
            _ = try channel.send(.write, cancellation: flag) { $0.bytes(Data(count: 1_000_000)) }
        }
        Thread.sleep(forTimeInterval: 0.5)
        let started = Date()
        adoptCancel(flag, after: 0)
        #expect(outcome.ended())
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.failed)
    }
}

/// Continuing files over SFTP, against the system's own `sftp-server`.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: systemSFTPServer))) struct NetworkAdoptSFTPAppend {
    let box: Sandbox
    let fileSystem: RemoteFileSystem
    let key = ServerKey(scheme: "sftp", host: "test.invalid")

    init() throws {
        box = try Sandbox()
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 10
        environment.options.values = values
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(
                profile: profile,
                environment: environment,
                transport: SFTPTransport(executable: systemSFTPServer, arguments: ["-e"])
            )
        }
        fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
    }

    func url(_ path: String) -> URL { key.url(path: box.url(path).path) }

    @Test func continuesCutsAndAppends() throws {
        try box.file("f.bin", "0123456789")
        #expect(fileSystem.capabilities(for: url("f.bin")).contains(.append))
        #expect(fileSystem.item(at: url("f.bin"))?.size == 10)

        var writer = try fileSystem.append(to: url("f.bin"), at: 4, cancellation: CancellationFlag())
        try writer.write(Data("abcdef".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(box.read("f.bin") == "0123abcdef")
        #expect(fileSystem.item(at: url("f.bin"))?.size == 10)

        // A shorter continuation cuts the file: nothing of the old tail is left.
        writer = try fileSystem.append(to: url("f.bin"), at: 2, cancellation: CancellationFlag())
        try writer.write(Data("Z".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(box.read("f.bin") == "01Z")
        #expect(fileSystem.item(at: url("f.bin"))?.size == 3)

        writer = try fileSystem.append(to: url("f.bin"), at: nil, cancellation: CancellationFlag())
        try writer.write(Data("+end".utf8))
        try writer.close(attributes: FileAttributes(permissions: 0o600))
        #expect(box.read("f.bin") == "01Z+end")
        #expect(fileSystem.item(at: url("f.bin"))?.size == 7 && fileSystem.item(at: url("f.bin"))?.permissions == 0o600)

        // Longer than the file, and not there: errors, and the file stays as it is.
        #expect(throws: (any Error).self) {
            _ = try fileSystem.append(to: url("f.bin"), at: 99, cancellation: CancellationFlag())
        }
        #expect(throws: (any Error).self) {
            _ = try fileSystem.append(to: url("none.bin"), at: nil, cancellation: CancellationFlag())
        }
        #expect(box.read("f.bin") == "01Z+end")
        #expect(!box.exists("none.bin"))
    }

    @Test func aLargeContinuationGoesThroughTheWindow() throws {
        let head = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let tail = Data((0..<900_000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) })
        try head.write(to: box.url("big.bin"))
        let writer = try fileSystem.append(to: url("big.bin"), at: 100_000, cancellation: CancellationFlag())
        try writer.write(tail)
        try writer.close(attributes: FileAttributes())
        #expect(try Data(contentsOf: box.url("big.bin")) == head + tail)
    }
}
