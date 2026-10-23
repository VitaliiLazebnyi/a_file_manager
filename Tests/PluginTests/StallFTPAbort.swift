import Foundation
import Testing

@testable import NetworkPlugin

/// The replies to an aborted transfer that come after the first one: the server writes them all at once, right
/// after the client dropped the data connection, so they are there when the client looks.
@Suite
internal struct StallFTPAbort {
    /// A connection whose download is answered, once the client dropped it, with `replies` in one write; the
    /// server hangs up afterwards when `hangsUp`.
    private static func aborted(_ replies: String, hangsUp: Bool = false) throws -> (
        CoverageNetworkServer, FTPConnection
    ) {
        let server = try CoverageNetworkServer(
            replies: [
                "RETR": .act { line in
                    line.sendAndWaitForTheClient(Data())
                    line.send(replies)
                    if hangsUp { line.hangUp() }
                }
            ]
        )
        let connection = try server.connected()
        _ = try connection.beginTransfer("RETR a", type: "I", restartAt: 0, cancellation: nil)
        connection.abortTransfer()
        return (server, connection)
    }

    /// A server that answers an abort with more than four replies is not listened to any longer.
    @Test
    internal func aServerThatKeepsReplyingIsLeft() throws {
        let (server, connection) = try Self.aborted("426 Aborted\r\n226 One\r\n226 Two\r\n226 Three\r\n226 Four")
        defer {
            connection.close()
            server.stop()
        }
        #expect(!connection.isUsable)
    }

    /// A second reply that breaks off where the server hung up leaves the connection unusable.
    @Test
    internal func aSecondReplyThatBreaksOffEndsTheConnection() throws {
        let (server, connection) = try Self.aborted("426 Aborted\r\n226-The first line of more", hangsUp: true)
        defer {
            connection.close()
            server.stop()
        }
        #expect(!connection.isUsable)
    }

    /// Up to four replies are read, and the connection is used again.
    @Test
    internal func fourRepliesAreRead() throws {
        let (server, connection) = try Self.aborted("426 Aborted\r\n226 One\r\n226 Two\r\n226 Three")
        defer {
            connection.close()
            server.stop()
        }
        #expect(connection.isUsable && connection.isAlive(cancellation: nil))
    }
}
