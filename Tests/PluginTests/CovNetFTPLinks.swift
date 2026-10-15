import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The links an FTP listing had no time for, asked about in the background: standing aside for commands, a
/// connection that breaks, and a login the background may not ask about.
@Suite
internal struct CovNetFTPLinks {
    /// A listing of `count` links to folders, `link0` to `link<count - 1>`.
    private static func links(_ count: Int) -> Data {
        Data((0..<count).map { "lrwxrwxrwx 1 u g 1 Jan 01 2020 link\($0) -> d\r\n" }.joined().utf8)
    }

    /// The background stands aside for commands that wait for its connection, and goes on after them.
    @Test
    internal func theBackgroundStandsAsideForCommands() throws {
        let (probe, first, second) = (Signal<Bool>(), Signal<Bool>(), Signal<Bool>())
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) == "LIST" ? "LIST" : command {
            case "LIST":
                line.transfer(Self.links(40), verdict: "226 Done")

            case "CWD /link32":
                _ = probe.wait()
                line.send("250 OK")

            case "SIZE /x1", "SIZE /x2":
                _ = (command == "SIZE /x1" ? first : second).wait()
                line.send("213 0")

            case "MDTM /x1", "MDTM /x2":
                line.send("213 20200101000000")

            default:
                return .standard
            }
            return .handled
        }
        let session = try bench.session()
        let resolved = CovNetResolvedLinks()
        session.onLinkResolved { path, _ in resolved.add(path) }
        var listed: [RemoteEntry] = []
        try session.list("/", showHidden: true, cancellation: nil) { entries in
            listed += entries
            return true
        }
        #expect(listed.count == 40 && listed.prefix(32).allSatisfy(\.isDirectory))
        // The background asks about the links that were left, and waits for the server's answer.
        #expect(Wait.until { bench.server.commands.contains("CWD /link32") })
        let commands = ["/x1", "/x2"]
            .map { path in AdoptOutcome { _ = try session.entry(at: path, cancellation: nil) } }
        #expect(Wait.until { session.waitingCommands == 2 })
        probe.set(true)
        // One command has the connection, the other waits, and the background stands aside for it.
        #expect(Wait.until { !bench.commands("SIZE /x").isEmpty })
        let firstAsked = bench.commands("SIZE /x").first == "SIZE /x1"
        (firstAsked ? first : second).set(true)
        #expect(Wait.until { bench.commands("SIZE /x").count == 2 })
        (firstAsked ? second : first).set(true)
        #expect(commands.allSatisfy { $0.ended() && !$0.failed })
        // Then it goes on with the links that were left.
        #expect(Wait.until { resolved.all.contains("/link39") })
        #expect(resolved.all.contains("/link32"))
    }

    /// A connection that breaks while the background asks about a link ends the background's round.
    @Test
    internal func aConnectionThatBreaksEndsTheRound() throws {
        let probe = Signal<Bool>()
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) == "LIST" ? "LIST" : command {
            case "LIST":
                line.transfer(Self.links(40), verdict: "226 Done")

            case "CWD /link32":
                _ = probe.wait()
                line.send("250 OK")

            default:
                return .standard
            }
            return .handled
        }
        let session = try bench.session()
        let resolved = CovNetResolvedLinks()
        session.onLinkResolved { path, _ in resolved.add(path) }
        try session.list("/", showHidden: true, cancellation: nil) { _ in true }
        #expect(Wait.until { bench.server.commands.contains("CWD /link32") })
        session.disconnect()
        probe.set(true)
        #expect(Wait.until { session.connectionCount == 0 })
        #expect(resolved.all.isEmpty)
    }

    /// The background opens a connection of its own when none is free, and asks nothing when its login is refused.
    @Test
    internal func theBackgroundAsksNothingWhenItsLoginIsRefused() throws {
        let logins = CovNetCount()
        let content = NetworkFixSFTP.pattern(8_000_000)
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "USER":
                logins.add()
                line.send(logins.value <= 2 ? "230 Welcome" : "530 Not now")

            case "RETR":
                line.transfer(content, verdict: "226 Sent")

            case "LIST":
                // The listing, and then the connection is gone: no link of it can be asked about there.
                line.transfer(Self.links(48), verdict: "226 Done")
                line.hangUp()

            default:
                return .standard
            }
            return .handled
        }
        let questions = CovNetCount()
        bench.environment.askCredentials = { _, _ in
            questions.add()
            return nil
        }
        let session = try bench.session()
        // A download holds the first connection; the listing gets a second one, which it loses.
        let download = try session.openRead("/big", cancellation: nil)
        defer { download.close() }
        #expect(try download.read(upToCount: 10)?.count == 10)
        var listed = 0
        try session.list("/", showHidden: true, cancellation: nil) { entries in
            listed += entries.count
            return true
        }
        #expect(listed == 48)
        // The background's own login is refused, and nobody is asked.
        #expect(Wait.until { logins.value >= 3 })
        #expect(questions.value == 0)
        session.disconnect()
    }
}
