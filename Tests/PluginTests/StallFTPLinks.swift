import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The FTP link resolver takes only a connection that is free when it looks: while a command holds the only one,
/// it puts its links back and asks about them later.
@Suite
internal struct StallFTPLinks {
    /// A listing of `count` links to folders, `link0` to `link<count - 1>`.
    private static func links(_ count: Int) -> Data {
        Data((0..<count).map { "lrwxrwxrwx 1 u g 1 Jan 01 2020 link\($0) -> d\r\n" }.joined().utf8)
    }

    /// The listing asks about 32 links itself and leaves 8; a command that waited for the connection gets it next,
    /// and while its answer is held the resolver finds no connection it may use.
    @Test
    internal func theResolverPutsItsLinksBackWhileACommandHoldsTheConnection() throws {
        let (listing, answer) = (Signal<Bool>(), Signal<Bool>())
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 1
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) == "LIST" ? "LIST" : command {
            case "LIST":
                _ = listing.wait()
                line.transfer(Self.links(40), verdict: "226 Done")

            case "SIZE /x":
                _ = answer.wait()
                line.send("213 0")

            case "MDTM /x":
                line.send("213 20200101000000")

            default:
                return .standard
            }
            return .handled
        }
        let session = try bench.session()
        let resolved = CovNetResolvedLinks()
        session.onLinkResolved { path, _ in resolved.add(path) }
        let listed = AdoptOutcome { try session.list("/", showHidden: true, cancellation: nil) { _ in true } }
        // While the listing has the only connection, a command waits for it.
        #expect(Wait.until { !bench.commands("LIST").isEmpty })
        let command = AdoptOutcome { _ = try session.entry(at: "/x", cancellation: nil) }
        #expect(Wait.until { session.waitingCommands == 1 })
        listing.set(true)
        #expect(listed.ended() && !listed.failed)
        // The command has the connection now, and its answer is held: the resolver goes without.
        #expect(Wait.until { !bench.commands("SIZE /x").isEmpty })
        #expect(Wait.until { session.linkRoundsPutBack > 0 })
        #expect(resolved.all.isEmpty)
        answer.set(true)
        #expect(command.ended() && !command.failed)
        // Then it asks about the links that were left.
        #expect(Wait.until { Set(resolved.all) == Set((32..<40).map { "/link\($0)" }) })
    }
}
