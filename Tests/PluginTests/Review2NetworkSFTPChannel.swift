import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The shared channel (review 2: N035, N036, N037, N060, N063, N064, N090, N093, N094, N095).
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct Review2NetworkSFTPChannel {
    /// A channel that answers nothing for a whole request's time is taken for dead and replaced.
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

    /// Closing a handle does not wait for the server, and the closing reaches it before the next request.
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

    /// Disconnecting ends a login under way and the calls waiting behind it, at once.
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

    /// A channel closed before it was started refuses to start instead of touching its closed pipe.
    @Test
    internal func aChannelClosedBeforeItStartsDoesNotStart() {
        // A disconnect may close the channel before the login starts it; the closed pipe must
        // not be touched (its handle raises, which ended the whole program).
        let channel = SFTPChannel(
            executable: "/bin/sleep",
            arguments: ["600"],
            environment: [:],
            writeTimeout: 60,
            names: nil
        )
        channel.close()
        #expect(throws: NetworkError.self) { try channel.start(timeout: 30, cancellation: nil) { true } }
        #expect(channel.isClosed)
    }

    /// A packet larger than the protocol allows ends the channel and its process.
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
        let channel = SFTPChannel(
            executable: FakeSFTPServer.python,
            arguments: [script.path],
            environment: [:],
            writeTimeout: 60,
            names: nil
        )
        try channel.start(timeout: Wait.ceiling, cancellation: nil) { true }
        #expect(throws: NetworkError.self) {
            _ = try channel.request(.realpath, timeout: 30, cancellation: nil) { $0.string(".") }
        }
        #expect(adoptWait { channel.isClosed })
        #expect(SFTPChannel.largestPacket <= 1 << 20)
    }

    /// Interrupting uploads in the middle of their packets leaves the channel whole for the other calls.
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
