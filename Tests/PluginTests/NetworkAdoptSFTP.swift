import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Cancelling against the SFTP test server that stops answering, while other transfers share the channel.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct NetworkAdoptSFTP {
    /// A cancelled listing and a cancelled question on a server that stopped answering end, and the
    /// channel stays open for the next request.
    @Test
    internal func aCancelledListingEndsAndTheChannelStaysOpen() throws {
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

    /// Interrupting one reader ends it alone: another transfer on the same channel goes on.
    @Test
    internal func interruptingOneReaderLeavesTheOtherTransfersAlone() throws {
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
        let outcome = AdoptOutcome {
            while try stuck.read(upToCount: 1 << 20) != nil {
                // Reads on until a read is never answered.
            }
        }
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
        withExtendedLifetime(token) {
            // The flag interrupts the transfer until here.
        }
    }

    /// Interrupting a writer whose requests are never answered ends it, and the channel serves a read after.
    @Test
    internal func interruptingAWriterEndsAWriteWhoseAnswersNeverCome() throws {
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
        withExtendedLifetime(token) {
            // The flag interrupts the transfer until here.
        }
    }

    /// A packet stuck in a full pipe ends when the flag is set, without waiting for the write time limit.
    @Test
    internal func aSendThatIsCancelledOnAFullPipeEnds() throws {
        let box = try Sandbox()
        let server = try FakeSFTPServer(root: box.url("."), box: box, mode: .stalled)
        let channel = SFTPChannel(
            executable: server.transport.executable,
            arguments: server.transport.arguments,
            environment: [:],
            writeTimeout: 600,
            names: nil
        )
        try channel.start(timeout: Wait.ceiling, cancellation: nil) { true }
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
