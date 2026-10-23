import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Data connections of FTP servers that refuse them, keep announcing them or confirm an abort twice.
@Suite
internal struct CoverageNetworkTransfers {
    /// A passive reply that names no port, and a refused PASV, refuse the transfer.
    @Test
    internal func aPassiveReplyWithoutAPortRefusesTheTransfer() throws {
        let server = try CoverageNetworkServer(replies: ["EPSV": "229 Somewhere", "PASV": "500 No passive mode"])
        let connection = try server.connected()
        defer { connection.close() }
        let error = #expect(throws: NetworkError.self) {
            try connection.beginTransfer("RETR a", type: "I", restartAt: 0, cancellation: nil)
        }
        #expect(CoverageNetworkServer.code(of: error) == 500)
    }

    /// A refused restart refuses the transfer, and a second transfer waits for the first.
    @Test
    internal func aRefusedRestartAndASecondTransferAreRefused() throws {
        let server = try CoverageNetworkServer(
            replies: [
                "REST": "502 No restarts",
                "RETR": .act { line in
                    line.send("150 Here it comes")
                    if let channel = line.acceptData() {
                        close(channel)
                    }
                }
            ]
        )
        let connection = try server.connected()
        defer { connection.close() }
        let refused = #expect(throws: NetworkError.self) {
            try connection.beginTransfer("RETR a", type: "I", restartAt: 5, cancellation: nil)
        }
        #expect(CoverageNetworkServer.code(of: refused) == 502)
        _ = try connection.beginTransfer("RETR a", type: "I", restartAt: 0, cancellation: nil)
        let error = #expect(throws: NetworkError.self) {
            try connection.beginTransfer("RETR b", type: "I", restartAt: 0, cancellation: nil)
        }
        #expect(CoverageNetworkServer.text(of: error)?.contains("still running") == true)
        connection.abandonTransfer()
        #expect(!connection.isUsable)
        // Nothing to end or drop any more.
        try connection.finishTransfer(cancellation: nil)
        connection.abandonTransfer()
        connection.abortTransfer()
        #expect(!connection.isUsable)
    }

    /// A server that keeps announcing the transfer is given up.
    @Test
    internal func aServerThatKeepsAnnouncingIsGivenUp() throws {
        let announcements = Array(repeating: "150 Still coming", count: 5).joined(separator: "\r\n")
        let server = try CoverageNetworkServer(
            replies: ["RETR": .act { line in line.transfer(Data("data".utf8), verdict: announcements) }]
        )
        let connection = try server.connected()
        defer { connection.close() }
        let stream = try connection.beginTransfer("RETR a", type: "I", restartAt: 0, cancellation: nil)
        var received = Data()
        while let block = try stream.read(upToCount: 100, timeout: Wait.ceiling, cancellation: nil) {
            received += block
        }
        #expect(received == Data("data".utf8))
        let error = #expect(throws: NetworkError.self) { try connection.finishTransfer(cancellation: nil) }
        #expect(CoverageNetworkServer.text(of: error) == "150 Still coming")
        #expect(!connection.isUsable)
    }

    /// An abort that the server confirms twice leaves the connection usable.
    @Test
    internal func anAbortConfirmedTwiceLeavesTheConnectionUsable() throws {
        let server = try CoverageNetworkServer(
            replies: [
                "RETR": .act { line in
                    line.sendAndWaitForTheClient(Data())
                    line.send("426 Transfer aborted\r\n226 Abort successful")
                }
            ]
        )
        let connection = try server.connected()
        defer { connection.close() }
        _ = try connection.beginTransfer("RETR a", type: "I", restartAt: 0, cancellation: nil)
        connection.abortTransfer()
        #expect(connection.isUsable && connection.isAlive(cancellation: nil))
    }
}
