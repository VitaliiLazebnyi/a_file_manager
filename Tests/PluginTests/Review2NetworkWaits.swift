import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Every wait ends (review 2: N010, N012, N026, N027, N035, N044, N046, N049, N050, N052, N054).
@Suite
internal struct Review2NetworkWaits {
    /// A thread that waits behind a login at its password question leaves when it is cancelled.
    @Test
    internal func aWaitBehindAnotherLoginCanBeCancelled() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "a")
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        // The first login sits at its password question for as long as the test lets it.
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let first = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + Wait.ceiling) == .success)

        // A second thread waits behind it, and leaves when it is cancelled.
        let flag = CancellationFlag()
        let second = AdoptOutcome {
            _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: false, cancellation: flag)
        }
        #expect(!second.ended(within: 0.5))
        flag.cancel()
        #expect(second.ended() && second.failed)

        // The main thread never waits behind a login at all: the question is answered there.
        // A thread that waits ends when the session is closed.
        let third = AdoptOutcome { try fixture.fileSystem.createDirectory(at: fixture.url("/made")) }
        #expect(!third.ended(within: 0.5))
        answer.signal()
        #expect(first.ended() && !first.failed)
        #expect(third.ended() && !third.failed && fixture.box.exists("srv/made"))
    }

    /// A call that waits behind a login without a cancellation flag ends when the session disconnects.
    @Test
    internal func disconnectEndsAWaitThatHasNoFlag() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return nil
        }
        let session = try fixture.center.session(for: fixture.key)
        let first = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(asked.wait(timeout: .now() + Wait.ceiling) == .success)
        // Called without a flag, it ends with the session.
        let waiting = AdoptOutcome { try session.makeDirectory("/made", cancellation: nil) }
        #expect(!waiting.ended(within: 0.5))
        let started = Date()
        session.disconnect()
        #expect(Date().timeIntervalSince(started) < 60, "closing returns at once")
        #expect(waiting.ended() && waiting.failed)
        answer.signal()
        #expect(first.ended() && first.failed)
    }

    /// Readers that hold every download connection make the next one fail with a reason, not hang.
    @Test
    internal func filesHeldOpenDoNotMakeTheNextOneWaitForEver() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        // Large enough that a file that is not read on is not finished behind the reader's back.
        for index in 0..<3 {
            try Data(repeating: UInt8(index), count: 8_000_000).write(to: fixture.box.url("srv/f\(index).bin"))
        }
        let session = try #require(try fixture.center.session(for: fixture.key) as? FTPSession)
        session.stallLimit = 1
        // Two viewers that paused: all the connections downloads may have.
        let held = try (0..<2)
            .map { index -> any FileReader in
                let reader = try fixture.fileSystem.read(fixture.url("/f\(index).bin"))
                #expect(try reader.read(upToCount: 10)?.count == 10)
                return reader
            }
        let third = try fixture.fileSystem.read(fixture.url("/f2.bin"))
        let outcome = Shared<[String]>([])
        let call = AdoptOutcome {
            do {
                _ = try third.read(upToCount: 10)
            } catch {
                outcome.modify { $0.append(error.localizedDescription) }
                throw error
            }
        }
        #expect(call.ended() && call.failed)
        #expect(outcome.value.first?.contains("held by open files") == true, "\(outcome.value)")
        // Once one of them is closed there is room again.
        held[0].close()
        #expect(try third.read(upToCount: 10)?.count == 10)
        third.close()
        held[1].close()
    }

    /// A login the user cancelled is tried again at once; a password question they refused is not.
    @Test
    internal func aCancelledLoginIsNotRememberedAsARefusal() throws {
        var options = TestFTPServer.Options()
        options.greetingDelay = 2
        let fixture = try FTPFixture(options)
        fixture.environment.declineMemory = 600
        try fixture.box.file("srv/a.txt", "a")
        let flag = CancellationFlag()
        adoptCancel(flag, after: 0.3)
        #expect(throws: (any Error).self) { _ = try fixture.center.connect(fixture.key, cancellation: flag) }
        // The user tries again at once: the server is asked, the earlier cancel says nothing.
        #expect(try fixture.names("/") == ["a.txt"])

        // A question the user refused is remembered, so one click does not ask several times.
        var secured = TestFTPServer.Options()
        (secured.user, secured.password) = ("anna", "pw")
        let other = try FTPFixture(secured)
        other.environment.declineMemory = 600
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var questions = 0
        other.environment.askCredentials = { _, _ in
            questions += 1
            return nil
        }
        #expect(throws: (any Error).self) { _ = try other.names("/") }
        #expect(throws: (any Error).self) { _ = try other.names("/") }
        #expect(questions == 1)
    }

    /// Closing a reader in the middle of a file returns at once and the connection is not lost.
    @Test
    internal func closingAReaderReturnsAtOnceAndGivesTheConnectionBack() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        try Data(repeating: 1, count: 8_000_000).write(to: fixture.box.url("srv/big.bin"))
        try fixture.box.file("srv/small.txt", "s")
        let session = try #require(try fixture.center.session(for: fixture.key) as? FTPSession)
        for _ in 0..<6 {
            let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
            #expect(try reader.read(upToCount: 100)?.count == 100)
            // In the middle of the file: the server is told in the background.
            reader.close()
            // Closed twice, and read after closing: nothing happens.
            reader.close()
            #expect(try reader.read(upToCount: 10) == nil)
        }
        #expect(fixture.settle(session))
        // Every connection came back or was closed; none is lost to the pool, and none was cut
        // while another thread had it.
        #expect(try fixture.download("/small.txt") == Data("s".utf8))
        #expect(session.connectionCount <= 2)
        #expect(Background.threadCount <= Background.mostThreads)
    }

    /// A `close` that races with the reader's own end of file never cuts the connection the next call gets.
    @Test
    internal func closingWhileAnotherThreadUsesTheConnectionNextDoesNotCutIt() throws {
        // The reader reaches the end of its file and gives the connection back; `close` from
        // another thread comes at the same moment. Whoever takes the connection next must not
        // find it cut. Many rounds, since it is a race.
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        try fixture.box.file("srv/tiny.txt", "t")
        _ = try fixture.center.connect(fixture.key)
        let failures = Shared<[String]>([])
        for round in 0..<60 {
            let reader = try fixture.fileSystem.read(fixture.url("/tiny.txt"))
            let done = DispatchSemaphore(value: 0)
            Thread {
                do {
                    while try reader.read(upToCount: 100) != nil {
                        // Read on to the end.
                    }
                } catch {
                    // Losing the race with `close` may end the read with an error; that is allowed.
                }
                done.signal()
            }
            .start()
            Thread {
                reader.close()
                done.signal()
            }
            .start()
            // Not retried when the connection is lost: a rename.
            do {
                try fixture.fileSystem.createDirectory(at: fixture.url("/d\(round)"))
            } catch {
                failures.modify { $0.append("round \(round): \(error.localizedDescription)") }
            }
            #expect(
                done.wait(timeout: .now() + Wait.ceiling) == .success
                    && done.wait(timeout: .now() + Wait.ceiling) == .success
            )
        }
        #expect(failures.value.isEmpty, "\(failures.value)")
    }

    /// Readers dropped while their transfers hang do not leave a thread each behind.
    @Test
    internal func manyDroppedTransfersDoNotPileUpThreads() throws {
        var options = TestFTPServer.Options()
        options.stallRETR = true
        let fixture = try FTPFixture(options) { values in
            values.parallelConnections = 8
            values.timeout = 2
        }
        try fixture.box.file("srv/f.bin", String(repeating: "z", count: 1_000))
        // A server that stopped answering, and a viewer that steps through files: every reader
        // is dropped without being closed while its transfer hangs.
        for _ in 0..<24 {
            var reader: (any FileReader)? = try fixture.fileSystem.read(fixture.url("/f.bin"))
            let pending = reader
            let read = AdoptOutcome { _ = try pending?.read(upToCount: 10) }
            reader?.interrupt()
            _ = read.ended()
            reader = nil
        }
        #expect(Background.threadCount <= Background.mostThreads)
        #expect(fixture.settle())
    }

    /// Keep-alive tests idle connections one at a time, and the pool keeps answering meanwhile.
    @Test
    internal func keepAliveTestsOneConnectionAtATimeAndKeepsThePoolUsable() throws {
        let fixture = try FTPFixture { values in
            values.keepAliveInterval = 0.5
            values.parallelConnections = 3
        }
        try fixture.box.file("srv/a.txt", "a")
        // Three connections that then sit idle.
        DispatchQueue.concurrentPerform(iterations: 3) { _ in _ = try? fixture.names("/") }
        #expect(adoptWait { fixture.server.commands.contains("NOOP") })
        // While they are being kept alive the pool answers as usual.
        for _ in 0..<5 { #expect(try fixture.names("/") == ["a.txt"]) }
        let session = try #require(try fixture.center.session(for: fixture.key) as? FTPSession)
        #expect(session.connectionCount <= 3)
        fixture.center.disconnect(fixture.key)
        #expect(fixture.settle(session))
    }

    /// Links are resolved in the background by one resolver that lets the listings go first.
    @Test
    internal func linksAreResolvedByOneResolverThatStandsAside() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options) { $0.parallelConnections = 1 }
        // Time stands still for the session: the background work does not give up on the links (it would after 20 s).
        let now = Date()
        fixture.environment.clock = { now }
        for folder in ["one", "two", "three"] {
            try fixture.box.folder("srv/\(folder)/d")
            for index in 0..<40 {
                try FileManager.default.createSymbolicLink(
                    at: fixture.box.url("srv/\(folder)/link\(index)"),
                    withDestinationURL: fixture.box.url("srv/\(folder)/d")
                )
            }
        }
        // Three folders full of links, read one after the other with a single connection: the
        // listings do not wait for the questions about the links of the folders before.
        let started = Date()
        for folder in ["one", "two", "three"] { #expect(try fixture.names("/" + folder).count == 41) }
        #expect(Date().timeIntervalSince(started) < 120, "the listings waited for the background work")
        func resolved(_ folder: String) -> Bool {
            let links =
                (try? fixture.fileSystem.list(fixture.url("/" + folder), showHidden: false))?.filter(\.isSymlink) ?? []
            return links.count == 40 && links.allSatisfy(\.isDirectory)
        }
        // The last folder, the one the user is in, comes first.
        #expect(adoptWait { resolved("three") })
        #expect(fixture.server.mostConnectionsAtOnce == 1)
        let session = try fixture.center.session(for: fixture.key)
        fixture.center.disconnect(fixture.key)
        #expect(fixture.settle(session))
    }
}
