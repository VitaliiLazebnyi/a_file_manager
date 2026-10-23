import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The connections to an FTP server and what runs on them.
@Suite
internal struct NetworkFixConnections {
    /// Collects strings from several threads.
    ///
    /// Unchecked: the lock guards the values.
    internal final class FailureBox: @unchecked Sendable {
        /// Guards `values`.
        private let lock = NSLock()
        /// What was added, in order.
        private var values: [String] = []

        /// Everything added so far.
        internal var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        /// Adds a string, from any thread.
        internal func add(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Eight reads and writes at once on a server get every byte right and stay within the connection limit.
    @Test
    internal func downloadsAndCopiesStayWithinTheConnectionLimit() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 2 }
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        for index in 0..<8 { try content.write(to: fixture.box.url("srv/f\(index).bin")) }
        _ = try fixture.center.connect(fixture.key)

        let failures = FailureBox()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                // Like a copy job: a file is open for reading while another is written on the same server.
                let reader = try fixture.fileSystem.read(fixture.url("/f\(index).bin"))
                defer { reader.close() }
                var data = try #require(try reader.read(upToCount: 50_000))
                try fixture.upload("/copy\(index).bin", content)
                while let block = try reader.read(upToCount: 64 * 1_024) { data.append(block) }
                if data != content { failures.add("content \(index)") }
            } catch {
                failures.add("\(error)")
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all)")
        for index in 0..<8 { #expect(try Data(contentsOf: fixture.box.url("srv/copy\(index).bin")) == content) }
        // Three slots for reading and three for writing, at the very most.
        #expect(fixture.server.mostConnectionsAtOnce <= 6, "\(fixture.server.mostConnectionsAtOnce) connections")
    }

    /// Ten downloads at once wait for a free connection and all arrive whole.
    @Test
    internal func manyDownloadsAtOnceWaitForAFreeConnection() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 2 }
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        for index in 0..<10 { try content.write(to: fixture.box.url("srv/f\(index).bin")) }
        _ = try fixture.center.connect(fixture.key)
        let failures = FailureBox()
        DispatchQueue.concurrentPerform(iterations: 10) { index in
            do {
                if try fixture.download("/f\(index).bin") != content { failures.add("content \(index)") }
            } catch {
                failures.add("\(error)")
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all)")
        #expect(fixture.server.mostConnectionsAtOnce <= 3, "\(fixture.server.mostConnectionsAtOnce) connections")
    }

    /// A server that refuses new connections as busy is asked again until one is made.
    @Test
    internal func aBusyServerIsAskedAgain() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 3 }
        try fixture.box.file("srv/a.txt", "a")
        try fixture.box.file("srv/big.bin", String(repeating: "x", count: 100_000))
        _ = try fixture.center.connect(fixture.key)
        // A file held open takes the one connection; the listing needs another, and the server refuses twice.
        let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
        defer { reader.close() }
        _ = try reader.read(upToCount: 10)
        fixture.server.options.busyGreetings = 2
        #expect(try fixture.names("/") == ["a.txt", "big.bin"])
        #expect(fixture.server.connectionsOpened == 4)
    }

    /// A command whose reply is lost fails and is not sent again; a question is asked again on a new
    /// connection.
    @Test
    internal func aCommandWhoseReplyIsLostIsNotRepeated() throws {
        let fixture = try FTPFixture()
        _ = try fixture.names("/")
        let session = try fixture.center.session(for: fixture.key)
        fixture.server.options.dropReplyFor = "MKD"
        #expect(throws: NetworkError.self) { try session.makeDirectory("/made", cancellation: nil) }
        fixture.server.options.dropReplyFor = nil
        #expect(fixture.box.exists("srv/made"))
        #expect(fixture.server.commands.filter { $0.hasPrefix("MKD") }.count == 1)
        // A question is asked again on a new connection.
        fixture.server.dropConnections()
        #expect(try fixture.names("/") == ["made"])
    }

    /// Closing a reader ends a read that waits for a server that does not send, long before the time limit.
    @Test
    internal func closingAReaderEndsAReadThatWaitsForTheServer() throws {
        let fixture = try FTPFixture { $0.timeout = 600 }
        try fixture.box.file("srv/f.bin", String(repeating: "z", count: 1_000))
        fixture.server.options.stallRETR = true
        let reader = try fixture.fileSystem.read(fixture.url("/f.bin"))
        let outcome = FailureBox()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            do {
                _ = try reader.read(upToCount: 100)
                outcome.add("returned")
            } catch {
                outcome.add("threw")
            }
            finished.signal()
        }
        .start()
        // Until the server has the request, the read is under way but there is nothing to cut.
        let waitUntil = Date().addingTimeInterval(Wait.ceiling)
        while !fixture.server.commands.contains(where: { $0.hasPrefix("RETR") }), Date() < waitUntil {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let started = Date()
        reader.close()
        // Long before the ten minutes the read would wait for the server by itself.
        #expect(finished.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.all == ["threw"], "\(outcome.all)")
    }

    /// A data connection that breaks in the middle is an error, not the end of the file.
    @Test
    internal func aDataConnectionThatBreaksIsAnErrorNotAnEnd() throws {
        let fixture = try FTPFixture()
        try Data(repeating: 7, count: 300_000).write(to: fixture.box.url("srv/f.bin"))
        fixture.server.options.resetRETRAfter = 100_000
        #expect(throws: (any Error).self) { _ = try fixture.download("/f.bin") }
    }

    /// A connection made to a host name knows the address it reached, which data connections then use.
    @Test
    internal func theDataConnectionGoesToTheControlConnectionsAddress() throws {
        let fixture = try FTPFixture()
        let stream = NetStream(host: "localhost", port: fixture.server.port, security: .plain)
        stream.start()
        defer { stream.close() }
        try stream.waitUntilReady(timeout: Wait.ceiling, cancellation: nil)
        #expect(stream.remoteAddress == "127.0.0.1")
    }

    /// Where links lead is asked once for each link whose target is not spelled as a folder, and not again
    /// on the next listing.
    @Test
    internal func linkTargetsAreAskedOnceAndNotAgain() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/realdir")
        try fixture.box.file("srv/real.txt", "r")
        let files = FileManager.default
        try files.createSymbolicLink(atPath: fixture.box.url("srv/ldir").path, withDestinationPath: "realdir")
        try files.createSymbolicLink(atPath: fixture.box.url("srv/lfile").path, withDestinationPath: "real.txt")
        try files.createSymbolicLink(atPath: fixture.box.url("srv/ldead").path, withDestinationPath: "nowhere")
        try files.createSymbolicLink(atPath: fixture.box.url("srv/lslash").path, withDestinationPath: "realdir/")

        let probes = { fixture.server.commands.filter { $0.hasPrefix("CWD /l") }.count }
        var items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true)
            .filter(\.isSymlink)
            .sorted { $0.name < $1.name }
        #expect(items.map(\.name) == ["ldead", "ldir", "lfile", "lslash"])
        #expect(items.map(\.isDirectory) == [false, true, false, true])
        // The one whose target is spelled as a folder is not asked about; the others once each.
        #expect(probes() == 3)
        items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true)
            .filter(\.isSymlink)
            .sorted { $0.name < $1.name }
        #expect(items.map(\.isDirectory) == [false, true, false, true])
        #expect(probes() == 3)
    }
}
