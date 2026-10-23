import Darwin.C
import Testing

@testable import NetworkPlugin

/// One FTP connection whose server breaks it off.
@Suite
internal struct CovNetFTPConnections {
    /// A connection the server resets in the middle of the login fails.
    @Test
    internal func aConnectionTheServerResetsFails() throws {
        let server = try CoverageNetworkServer(
            replies: [
                "FEAT": .act { line in
                    // Closed without the goodbye of TCP: the client's next read fails.
                    var reset = linger(l_onoff: 1, l_linger: 0)
                    setsockopt(line.socket, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
                    line.hangUp()
                }
            ]
        )
        defer { server.stop() }
        let connection = server.connection { _ in
            // The usual configuration.
        }
        defer { connection.close() }
        let error = #expect(throws: NetworkError.self) { try connection.connect(cancellation: nil) }
        #expect(CovNetErrorKind(error) == .connectionFailed)
    }
}
