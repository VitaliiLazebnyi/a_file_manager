import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The SFTP client against the delaying test server: a window of requests, answers out of
/// order, short reads, failures, and requests that are never answered.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct NetworkFixSFTP {
    /// The sandbox; the server serves its `srv` folder.
    internal let box: Sandbox
    /// The connections, whose sessions start the fake server as their transport.
    internal let center: ConnectionCenter
    /// The SFTP file system over the center.
    internal let fileSystem: RemoteFileSystem
    /// The server; its host name is never looked up.
    internal let key = ServerKey(scheme: "sftp", host: "fake.invalid")

    /// A server that behaves, with a time limit of ten seconds (the suite's own set-up).
    internal init() throws {
        try self.init(mode: .normal, timeout: 10)
    }

    /// A server in the mode given, with a time limit of ten seconds.
    internal init(mode: FakeSFTPServer.Mode) throws {
        try self.init(mode: mode, timeout: 10)
    }

    /// A server in the mode given, and the time limit the sessions wait for an answer.
    internal init(mode: FakeSFTPServer.Mode, timeout: TimeInterval) throws {
        box = try Sandbox()
        try box.folder("srv")
        let server = try FakeSFTPServer(root: box.url("srv"), box: box, mode: mode)
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = timeout
        environment.options.values = values
        center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(profile: profile, environment: environment, transport: server.transport)
        }
        fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
    }

    /// Bytes that do not repeat soon, so a piece in the wrong place shows.
    internal static func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ $0 / 997) })
    }

    /// The location of a path on the server.
    internal func url(_ path: String) -> URL { key.url(path: path) }

    /// Four megabytes go up and come back whole through many requests in flight, also after jumps and
    /// many small reads, and the requests really overlap.
    @Test
    internal func movesDataThroughTheWindowInBothDirections() throws {
        let content = Self.pattern(4_000_000)
        let started = Date()
        let writer = try fileSystem.write(url("/big.bin"))
        for start in stride(from: 0, to: content.count, by: 1_000_000) {
            try writer.write(content.subdata(in: start..<min(start + 1_000_000, content.count)))
        }
        try writer.close(attributes: FileAttributes())
        #expect(try Data(contentsOf: box.url("srv/big.bin")) == content)

        let reader = try fileSystem.read(url("/big.bin"))
        var read = Data()
        while let block = try reader.read(upToCount: 1 << 20) { read.append(block) }
        #expect(read == content)
        // Jumps and small reads, which the window must discard and restart.
        for position in [3_990_000, 17, 1_234_567, 1_234_568, 2_000_000, 40] {
            try reader.seek(to: UInt64(position))
            #expect(try reader.read(upToCount: 5_000) == content.subdata(in: position..<position + 5_000))
        }
        // Many small reads one after the other, the pattern of a viewer.
        try reader.seek(to: 100_000)
        var small = Data()
        for _ in 0..<60 { small.append(try #require(try reader.read(upToCount: 7_777))) }
        #expect(small == content.subdata(in: 100_000..<100_000 + 60 * 7_777))
        try reader.seek(to: UInt64(content.count))
        #expect(try reader.read(upToCount: 10) == nil)
        reader.close()
        // The requests overlapped: the server owed many answers at one moment. (One after the
        // other, 250 requests at 20 to 60 ms each would also take far longer than this did on an
        // idle machine; the time is not asserted, it says little on a busy one.)
        let peak = Int((try? String(contentsOf: box.url("sftp-peak.log"), encoding: .utf8)) ?? "") ?? 0
        #expect(
            peak >= 4,
            "at most \(peak) requests were unanswered at a time, after \(Date().timeIntervalSince(started)) s"
        )
    }

    /// A read that fails from some position on delivers every byte before it, then the error.
    @Test
    internal func aFailingReadDeliversWhatCameBeforeIt() throws {
        let suite = try Self(mode: .failingReads)
        let content = Self.pattern(300_000)
        try content.write(to: suite.box.url("srv/f.bin"))
        let reader = try suite.fileSystem.read(suite.url("/f.bin"))
        defer { reader.close() }
        var got = Data()
        var failed = false
        do {
            while let block = try reader.read(upToCount: 1 << 20) { got.append(block) }
        } catch {
            failed = true
        }
        #expect(failed && got == content.prefix(98_304))
    }

    /// A request that is never answered times out alone: the channel stays open and the other transfer
    /// and new requests go on.
    @Test
    internal func aRequestThatTimesOutDoesNotCloseTheChannel() throws {
        let suite = try Self(mode: .hangingStat, timeout: 2)
        let content = Self.pattern(500_000)
        try content.write(to: suite.box.url("srv/f.bin"))
        let session = try suite.center.session(for: suite.key)
        _ = try session.connect(cancellation: nil)
        let reader = try suite.fileSystem.read(suite.url("/f.bin"))
        defer { reader.close() }
        #expect(try reader.read(upToCount: 10) == content.prefix(10))

        // The server goes on answering other requests while one of them hangs: it is slow with
        // that one, not gone. (A server that says nothing at all for the whole time is given
        // up; see `Review2NetworkSFTPTests`.)
        let stop = CancellationFlag()
        let asking = Thread {
            while !stop.isCancelled { _ = try? session.entry(at: "/f.bin") }
        }
        asking.start()
        defer { stop.cancel() }
        let started = Date()
        #expect(throws: NetworkError.self) { _ = try session.entry(at: "/hang") }
        // At the time limit of two seconds, not at some multiple of it.
        #expect(Date().timeIntervalSince(started) < 120)
        // The other transfer and new requests go on over the same channel.
        #expect(session.isConnected)
        var rest = content.prefix(10)
        while let block = try reader.read(upToCount: 1 << 20) { rest.append(block) }
        #expect(rest == content)
        #expect(try session.entry(at: "/f.bin")?.size == 500_000)
    }

    /// A write into a pipe nobody reads fails after the write time limit and closes the channel, and later
    /// requests fail at once.
    @Test
    internal func aStalledPipeFailsInsteadOfHanging() throws {
        let scratch = try Sandbox()
        let server = try FakeSFTPServer(root: scratch.url("."), box: scratch, mode: .stalled)
        let channel = SFTPChannel(
            executable: server.transport.executable,
            arguments: server.transport.arguments,
            environment: [:],
            writeTimeout: 1,
            names: nil
        )
        try channel.start(timeout: Wait.ceiling, cancellation: nil) { true }
        defer { channel.close() }
        let started = Date()
        // A megabyte cannot be written into a pipe that nobody reads.
        #expect(throws: NetworkError.self) {
            _ = try channel.send(.write, cancellation: nil) { $0.bytes(Data(count: 1_000_000)) }
        }
        // After the second the write may take, not after a wait without end.
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(channel.isClosed)
        // Later requests fail at once.
        #expect(throws: NetworkError.self) { _ = try channel.send(.read, cancellation: nil) { $0.bytes(Data()) } }
    }
}
