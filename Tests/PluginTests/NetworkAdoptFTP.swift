import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Cancelling and interrupting listings, reads and writes against the FTP test server.
@Suite
internal struct NetworkAdoptFTP {
    /// The connections the FTP session holds now.
    private func connectionCount(_ fixture: FTPFixture) throws -> Int {
        try #require(try fixture.center.session(for: fixture.key) as? FTPSession).connectionCount
    }

    /// A listing cancelled while the server is slow to send it ends at once, also when streamed, and its
    /// connection is not used again.
    @Test(arguments: [true, false])
    internal func aCancelledListingEndsAtOnceAndGivesTheConnectionUp(streaming: Bool) throws {
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

    /// A flag that is set already stops a question, a listing, a read and a write before anything is sent.
    @Test
    internal func aFlagThatIsSetAlreadyStopsEverythingBeforeItStarts() throws {
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

    /// A cancelled listing is not remembered: the next question asks the server.
    @Test
    internal func aCancelledListingIsNotRemembered() throws {
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

    /// Interrupting a reader ends a read that waits for the server; later calls fail and the connection
    /// is given up.
    @Test
    internal func interruptingAReaderEndsAReadThatWaitsForTheServer() throws {
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
        withExtendedLifetime(token) {
            // The flag interrupts the transfer until here.
        }
        // Interrupting again, or after the end, does nothing.
        reader.interrupt()
    }

    /// A reader interrupted before its first read never sends RETR.
    @Test
    internal func aReaderInterruptedBeforeItsFirstReadNeverStarts() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/f.bin", "abc")
        let reader = try fixture.fileSystem.read(fixture.url("/f.bin"))
        reader.interrupt()
        #expect(throws: (any Error).self) { _ = try reader.read(upToCount: 10) }
        reader.close()
        #expect(!fixture.server.commands.contains { $0.hasPrefix("RETR") })
    }

    /// Interrupting a writer ends a write blocked on a server that reads nothing; later calls fail.
    @Test
    internal func interruptingAWriterEndsAWriteThatWaitsForTheServer() throws {
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
        withExtendedLifetime(token) {
            // The flag interrupts the transfer until here.
        }
        writer.interrupt()
    }
}
