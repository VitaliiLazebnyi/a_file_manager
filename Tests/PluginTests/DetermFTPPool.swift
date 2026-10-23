import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Downloads on connections of the pool that died while they were idle, with a clock of the test's own, so the
/// connection is old (or not) whatever the load of the machine.
@Suite
internal struct DetermFTPPool {
    /// A download from a stale connection that died is started on a new one: the dead one gives its slot back.
    @Test
    internal func aDownloadOnAStaleConnectionThatDiedGoesToANewOne() throws {
        let clock = CoverageNetworkClock()
        let bench = try CovNetFTPBench { _ in
            // The usual options.
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "NOOP":
                line.hangUp()

            case "RETR":
                line.transfer(Data("content".utf8), verdict: "226 Sent")

            default:
                return .standard
            }
            return .handled
        }
        bench.environment.clock = { clock.now }
        let session = try bench.session()
        _ = try session.connect(cancellation: nil)
        clock.advance(by: 21)
        let reader = try session.openRead("/f", cancellation: nil)
        defer { reader.close() }
        #expect(try reader.read(upToCount: 100) == Data("content".utf8))
        #expect(bench.commands("NOOP").count == 1 && bench.commands("USER").count == 2)
    }

    /// A download on a connection that broke while it sat idle (not long enough to be tested first) is done once
    /// more on a new connection.
    @Test
    internal func aDownloadOnAConnectionThatBrokeIsDoneAgainOnANewOne() throws {
        let clock = CoverageNetworkClock()
        let passives = CovNetCount()
        let bench = try CovNetFTPBench { _ in
            // The usual options.
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "EPSV":
                passives.add()
                // The first connection is gone by the time the download asks for its data connection.
                guard passives.value > 1 else {
                    line.hangUp()
                    return .handled
                }
                return .standard

            case "RETR":
                line.transfer(Data("content".utf8), verdict: "226 Sent")

            default:
                return .standard
            }
            return .handled
        }
        bench.environment.clock = { clock.now }
        let session = try bench.session()
        _ = try session.connect(cancellation: nil)
        let reader = try session.openRead("/f", cancellation: nil)
        defer { reader.close() }
        #expect(try reader.read(upToCount: 100) == Data("content".utf8))
        #expect(bench.commands("NOOP").isEmpty && bench.commands("USER").count == 2 && passives.value == 2)
    }
}
