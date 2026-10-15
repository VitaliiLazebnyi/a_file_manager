import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Files written over SFTP: writers used after the end, dropped, or cut off from their session.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct CovNetSFTPWriting {
    /// A writer that was closed takes nothing more, and closing it again does nothing.
    @Test
    internal func aClosedWriterTakesNothingMore() throws {
        let bench = try CovNetSFTPBench()
        let session = bench.session()
        defer { session.disconnect() }
        let writer = try session.openWrite("/up.bin", cancellation: nil)
        try writer.write(Data("text".utf8))
        try writer.close(attributes: FileAttributes())
        let asked = bench.requests.count
        try writer.close(attributes: FileAttributes())
        let error = #expect(throws: NetworkError.self) { try writer.write(Data("more".utf8)) }
        #expect(CovNetErrorKind(error) == .connectionLost)
        #expect(bench.requests.count == asked && bench.box.read("srv/up.bin") == "text")
    }

    /// A writer that is dropped without closing cuts the file back to what was confirmed and closes it.
    @Test(arguments: [0, 1_000])
    internal func aDroppedWriterCutsAndClosesItsFile(written: Int) throws {
        let bench = try CovNetSFTPBench()
        let session = bench.session()
        defer { session.disconnect() }
        do {
            let writer = try session.openWrite("/up.bin", cancellation: nil)
            if written > 0 {
                try writer.write(NetworkFixSFTP.pattern(written))
            }
        }
        #expect(Wait.until { bench.requests.suffix(2) == ["10", "4"] })
        #expect(bench.box.read("srv/up.bin")?.isEmpty == true)
    }

    /// A writer whose session was disconnected fails to write, and fails to close.
    @Test
    internal func aWriterWithoutItsSessionFails() throws {
        let bench = try CovNetSFTPBench()
        let session = bench.session()
        let writing = try session.openWrite("/a.bin", cancellation: nil)
        let closing = try session.openWrite("/b.bin", cancellation: nil)
        session.disconnect()
        let written = #expect(throws: NetworkError.self) { try writing.write(Data("text".utf8)) }
        #expect(CovNetErrorKind(written) == .connectionLost)
        let closed = #expect(throws: NetworkError.self) { try closing.close(attributes: FileAttributes()) }
        #expect(CovNetErrorKind(closed) == .connectionLost)
    }
}
