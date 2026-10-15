import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Downloads from an FTP server read, sought, cut short and dropped.
@Suite
internal struct CoverageNetworkReaders {
    /// A hundred bytes: `0123456789` ten times.
    private static let hundred = Data(String(repeating: "0123456789", count: 10).utf8)

    /// A server with `/hundred`, `/thirty` (its first thirty bytes), `/stall` (ten bytes, then
    /// nothing until the client gives up) and `/text` (a line end split across two blocks).
    private static func server() throws -> CoverageNetworkServer {
        try CoverageNetworkServer { command, line in
            switch command {
            case "RETR /hundred":
                line.transfer(hundred, verdict: "226 Done")

            case "RETR /thirty":
                line.transfer(hundred.prefix(30), verdict: "226 Done")

            case "RETR /stall":
                line.sendAndWaitForTheClient(hundred.prefix(10))
                line.send("426 Aborted")

            case "RETR /text":
                line.send("150 Here it comes")
                if let channel = line.acceptData() {
                    _ = CoverageNetworkServer.sendAll(channel, Data("\r".utf8))
                    // The rest of the line end comes in a block of its own.
                    Thread.sleep(forTimeInterval: 0.2)
                    _ = CoverageNetworkServer.sendAll(channel, Data("\nx\r".utf8))
                    close(channel)
                }
                line.send("226 Done")

            default:
                return .standard
            }
            return .handled
        }
    }

    /// A seek a little forward reads past the bytes; one beyond the end starts anew there.
    @Test
    internal func seekingForwardReadsOrStartsAnew() throws {
        let server = try Self.server()
        let session = try server.session()
        defer { session.disconnect() }
        let reader = try session.openRead("/hundred", cancellation: nil)
        #expect(try reader.read(upToCount: 10) == Self.hundred.prefix(10))
        try reader.seek(to: 10)
        try reader.seek(to: 20)
        #expect(try reader.read(upToCount: 5) == Data("01234".utf8))
        reader.close()
        let short = try session.openRead("/thirty", cancellation: nil)
        #expect(try short.read(upToCount: 10)?.count == 10)
        try short.seek(to: 200)
        short.close()
        #expect(throws: NetworkError.self) { try short.seek(to: 0) }
    }

    /// A transfer that stops while a seek reads past bytes ends the seek with an error.
    @Test
    internal func aStallDuringASeekEndsIt() throws {
        let server = try Self.server()
        let session = try server.center { values in values.timeout = 1 }.session(for: server.key)
        defer { session.disconnect() }
        let reader = try session.openRead("/stall", cancellation: nil)
        #expect(try reader.read(upToCount: 5)?.count == 5)
        #expect(throws: NetworkError.self) { try reader.seek(to: 50) }
        reader.close()
    }

    /// In text mode a line end split across blocks is read as one, a CR at the very end is
    /// kept, and seeking is not possible.
    @Test
    internal func textModeJoinsLineEnds() throws {
        let server = try Self.server()
        let session = try server.center { values in values.transferMode = .text }.session(for: server.key)
        defer { session.disconnect() }
        let reader = try session.openRead("/text", cancellation: nil)
        var data = Data()
        while let block = try reader.read(upToCount: 64) {
            data += block
        }
        #expect(data == Data("\nx\r".utf8))
        #expect(try reader.read(upToCount: 64) == nil)
        #expect(throws: FileSystemError.self) { try reader.seek(to: 0) }
        reader.close()
    }

    /// A reader dropped in the middle, or interrupted and closed, gives its connection back.
    @Test
    internal func droppedAndInterruptedReadersGiveTheConnectionBack() throws {
        let server = try Self.server()
        let session = try server.session()
        defer { session.disconnect() }
        do {
            let reader = try session.openRead("/stall", cancellation: nil)
            #expect(try reader.read(upToCount: 5)?.count == 5)
        }
        #expect(Background.waitUntilIdle(lane: session, timeout: 300))
        let interrupted = try session.openRead("/stall", cancellation: nil)
        #expect(try interrupted.read(upToCount: 5)?.count == 5)
        interrupted.interrupt()
        interrupted.close()
        #expect(Background.waitUntilIdle(lane: session, timeout: 300))
        #expect(server.commands.filter { $0 == "RETR /stall" }.count == 2)
    }
}
