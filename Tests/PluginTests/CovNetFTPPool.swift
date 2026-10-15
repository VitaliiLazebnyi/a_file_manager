import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The pool of an FTP session: waits for a connection that end, a server without room, files that hold every
/// connection, connections the keep-alive tests, and connections that went stale.
@Suite
internal struct CovNetFTPPool {
    /// Answers `SIZE` (after `hold` for `/slow`) and `MDTM`, so a question about an entry is answered.
    private static func entries(
        _ command: String,
        _ line: CoverageNetworkServer.Line,
        hold: Signal<Bool>
    ) -> CoverageNetworkServer.Handling {
        switch CoverageNetworkServer.verb(command) {
        case "SIZE":
            if command == "SIZE /slow" {
                _ = hold.wait()
            }
            line.send("213 0")

        case "MDTM":
            line.send("213 20200101000000")

        default:
            return .standard
        }
        return .handled
    }

    /// A bench of one connection whose `SIZE /slow` waits for `hold`, connected and busy with that question.
    private func busy(_ hold: Signal<Bool>) throws -> (bench: CovNetFTPBench, slow: AdoptOutcome) {
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
        } script: { command, line in
            Self.entries(command, line, hold: hold)
        }
        let session = try bench.session()
        _ = try session.connect(cancellation: nil)
        let slow = AdoptOutcome { _ = try session.entry(at: "/slow", cancellation: nil) }
        _ = Wait.until { bench.server.commands.contains("SIZE /slow") }
        return (bench, slow)
    }

    /// A command that waits for a connection ends when the session is disconnected.
    @Test
    internal func aWaitForAConnectionEndsWithTheSession() throws {
        let hold = Signal<Bool>()
        let (bench, slow) = try busy(hold)
        let session = try bench.session()
        let waiting = AdoptOutcome { _ = try session.entry(at: "/b", cancellation: nil) }
        #expect(Wait.until { session.waitingCommands == 1 })
        session.disconnect()
        #expect(waiting.ended() && CovNetErrorKind(waiting.thrown) == .notConnected)
        hold.set(true)
        #expect(slow.ended())
    }

    /// A command that waits for a connection ends with its flag.
    @Test
    internal func aWaitForAConnectionEndsWithTheFlag() throws {
        let hold = Signal<Bool>()
        let (bench, slow) = try busy(hold)
        let session = try bench.session()
        let flag = CancellationFlag()
        let waiting = AdoptOutcome { _ = try session.entry(at: "/b", cancellation: flag) }
        #expect(Wait.until { session.waitingCommands == 1 })
        flag.cancel()
        #expect(waiting.ended() && CovNetErrorKind(waiting.thrown) == .cancelled)
        hold.set(true)
        #expect(slow.ended() && !slow.failed)
    }

    /// A server that has no room for another connection is quoted when the wait for one ends.
    @Test
    internal func aServerWithoutRoomIsQuotedWhenTheWaitEnds() throws {
        let (hold, logins) = (Signal<Bool>(), CovNetCount())
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 2
        } script: { command, line in
            guard CoverageNetworkServer.verb(command) == "USER" else {
                return Self.entries(command, line, hold: hold)
            }
            logins.add()
            line.send(logins.value == 1 ? "230 Welcome" : "421 Too many connections from your address")
            return .handled
        }
        let session = try bench.session()
        session.stallLimit = 0.3
        _ = try session.connect(cancellation: nil)
        let slow = AdoptOutcome { _ = try session.entry(at: "/slow", cancellation: nil) }
        #expect(Wait.until { bench.server.commands.contains("SIZE /slow") })
        let error = #expect(throws: NetworkError.self) { _ = try session.entry(at: "/b", cancellation: nil) }
        #expect(CoverageNetworkServer.code(of: error) == 421)
        hold.set(true)
        #expect(slow.ended() && !slow.failed)
    }

    /// An upload that waits for a slot held by other uploads says so when the wait ends.
    @Test
    internal func anUploadWithoutASlotSaysWhyWhenTheWaitEnds() throws {
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "STOR":
                line.send("150 Send it")
                _ = line.receiveData()
                line.send("226 Stored")

            case "SIZE":
                line.send("213 0")

            default:
                return .standard
            }
            return .handled
        }
        let session = try bench.session()
        session.stallLimit = 0.3
        let writers = try ["/one", "/two"].map { try session.openWrite($0, cancellation: nil) }
        let error = #expect(throws: NetworkError.self) { _ = try session.openWrite("/three", cancellation: nil) }
        #expect(CovNetErrorKind(error) == .busy && error?.localizedDescription.contains("uploads") == true)
        for writer in writers {
            try writer.close(attributes: FileAttributes())
        }
    }

    /// A connection the keep-alive is testing is not waited for: another one is opened.
    @Test
    internal func aConnectionTheKeepAliveTestsIsNotWaitedFor() throws {
        let hold = Signal<Bool>()
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
            values.keepAliveInterval = 0.5
        } script: { command, line in
            guard CoverageNetworkServer.verb(command) == "NOOP" else {
                return Self.entries(command, line, hold: hold)
            }
            _ = hold.wait()
            line.send("200 OK")
            return .handled
        }
        let session = try bench.session()
        session.returnGrace = 0
        _ = try session.connect(cancellation: nil)
        #expect(Wait.until { bench.server.commands.contains("NOOP") })
        #expect(try session.entry(at: "/b", cancellation: nil)?.name == "b")
        #expect(bench.commands("USER").count == 2)
        hold.set(true)
    }

    /// A connection that sat idle for long and died meanwhile is replaced by a new one.
    @Test
    internal func aStaleConnectionThatDiedIsReplaced() throws {
        let (hold, clock) = (Signal<Bool>(), CoverageNetworkClock())
        let bench = try CovNetFTPBench { _ in
            // The usual options.
        } script: { command, line in
            guard CoverageNetworkServer.verb(command) == "NOOP" else {
                return Self.entries(command, line, hold: hold)
            }
            line.hangUp()
            return .handled
        }
        bench.environment.clock = { clock.now }
        let session = try bench.session()
        _ = try session.connect(cancellation: nil)
        clock.advance(by: 21)
        #expect(try session.entry(at: "/b", cancellation: nil)?.name == "b")
        #expect(bench.commands("NOOP").count == 1 && bench.commands("USER").count == 2)
    }

    /// A download whose connection cannot log in gives its slot back.
    @Test
    internal func aDownloadWhoseLoginFailsGivesItsSlotBack() throws {
        let logins = CovNetCount()
        let content = NetworkFixSFTP.pattern(8_000_000)
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "USER":
                logins.add()
                line.send(logins.value == 1 ? "230 Welcome" : "530 Not you")

            case "RETR":
                line.transfer(content, verdict: "226 Sent")

            default:
                return .standard
            }
            return .handled
        }
        bench.environment.askCredentials = { _, _ in nil }
        let session = try bench.session()
        let first = try session.openRead("/big", cancellation: nil)
        defer { first.close() }
        #expect(try first.read(upToCount: 10)?.count == 10)
        let second = try session.openRead("/big", cancellation: nil)
        defer { second.close() }
        #expect(throws: NetworkError.self) { _ = try second.read(upToCount: 10) }
        #expect(session.connectionCount == 1)
    }

    /// A connection whose login ends after the session was disconnected is cut, not kept.
    @Test
    internal func aConnectionLoggedInAfterTheDisconnectIsCut() throws {
        let hold = Signal<Bool>()
        let bench = try CovNetFTPBench { _ in
            // The usual options.
        } script: { command, line in
            guard CoverageNetworkServer.verb(command) == "USER" else {
                return .standard
            }
            _ = hold.wait()
            line.send("230 Welcome")
            return .handled
        }
        let session = try bench.session()
        let flag = CancellationFlag()
        let connecting = AdoptOutcome { _ = try session.connect(cancellation: flag) }
        #expect(Wait.until { !bench.commands("USER").isEmpty })
        session.disconnect()
        hold.set(true)
        #expect(connecting.ended())
        #expect(!session.isConnected && Wait.until { session.connectionCount == 0 })
    }

    /// The keep-alive lets a spare connection go after two minutes without use, and keeps one.
    @Test
    internal func theKeepAliveLetsASpareConnectionGo() throws {
        let (hold, clock) = (Signal<Bool>(), CoverageNetworkClock())
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 2
            values.keepAliveInterval = 0.5
        } script: { command, line in
            if command == "SIZE /two" {
                _ = hold.wait()
            }
            return Self.entries(command, line, hold: hold)
        }
        bench.environment.clock = { clock.now }
        let session = try bench.session()
        // Two connections, both busy at once, then idle.
        let both = ["/slow", "/two"].map { path in AdoptOutcome { _ = try session.entry(at: path, cancellation: nil) } }
        #expect(Wait.until { session.connectionCount == 2 && bench.commands("SIZE").count == 2 })
        hold.set(true)
        #expect(both.allSatisfy { $0.ended() && !$0.failed })
        clock.advance(by: 200)
        #expect(Wait.until { session.connectionCount == 1 })
        #expect(Wait.until { bench.commands("QUIT").count == 1 })
    }
}
