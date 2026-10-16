import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Files read over SFTP: servers that answer reads oddly, small jumps, and readers that are dropped.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct CovNetSFTPReading {
    /// A bench whose server in `mode` has `content` in `f.bin`.
    private func serving(_ mode: FakeSFTPServer.Mode, _ content: Data) throws -> CovNetSFTPBench {
        let bench = try CovNetSFTPBench(mode: mode)
        try content.write(to: bench.box.url("srv/f.bin"))
        return bench
    }

    /// Nothing is asked for a read of no bytes.
    @Test
    internal func aReadOfNoBytesAsksNothing() throws {
        let bench = try serving(.normal, NetworkFixSFTP.pattern(100_000))
        let session = bench.session()
        defer { session.disconnect() }
        let reader = try session.openRead("/f.bin", cancellation: nil)
        #expect(try reader.read(upToCount: 0) == nil)
        reader.close()
        reader.close()
    }

    /// An answer with more bytes than were asked for is an error.
    @Test
    internal func anAnswerWithMoreThanWasAskedForIsAnError() throws {
        let bench = try serving(.overlong, NetworkFixSFTP.pattern(100_000))
        let session = bench.session()
        defer { session.disconnect() }
        let reader = try session.openRead("/f.bin", cancellation: nil)
        let error = #expect(throws: NetworkError.self) { _ = try reader.read(upToCount: 10) }
        #expect(CovNetErrorKind(error) == .unexpected)
        reader.close()
    }

    /// An answer without bytes is the end of the file.
    @Test
    internal func anAnswerWithoutBytesIsTheEnd() throws {
        let bench = try serving(.emptyData, NetworkFixSFTP.pattern(100_000))
        let session = bench.session()
        defer { session.disconnect() }
        let reader = try session.openRead("/f.bin", cancellation: nil)
        #expect(try reader.read(upToCount: 10) == nil)
        reader.close()
    }

    /// A server that never answers with more than it did three times running is asked for no more from then on.
    @Test
    internal func aServerThatAnswersShortIsAskedForLess() throws {
        let content = NetworkFixSFTP.pattern(100_000)
        let bench = try serving(.shortReads, content)
        let session = bench.session()
        defer { session.disconnect() }
        let reader = try session.openRead("/f.bin", cancellation: nil)
        var read = Data()
        while let block = try reader.read(upToCount: 40_000) { read.append(block) }
        reader.close()
        #expect(read == content)
        let lengths = ((try? String(contentsOf: bench.box.url("sftp-reads.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n")
        #expect(lengths.first == "32768" && lengths.contains("1000"))
    }

    /// A jump to where the reader is changes nothing, and a short one forward stays within what was read.
    @Test
    internal func shortJumpsStayWithinWhatWasRead() throws {
        let content = NetworkFixSFTP.pattern(100_000)
        let bench = try serving(.shortReads, content)
        let session = bench.session()
        defer { session.disconnect() }
        let reader = try session.openRead("/f.bin", cancellation: nil)
        #expect(try reader.read(upToCount: 10) == content.prefix(10))
        try reader.seek(to: 10)
        try reader.seek(to: 15)
        #expect(try reader.read(upToCount: 5) == content.subdata(in: 15..<20))
        reader.close()
    }

    /// A reader that is dropped without closing has its file closed all the same.
    @Test
    internal func aDroppedReaderClosesItsFile() throws {
        let bench = try CovNetSFTPBench()
        try NetworkFixSFTP.pattern(100_000).write(to: bench.box.url("srv/f.bin"))
        let session = bench.session()
        defer { session.disconnect() }
        do {
            let reader = try session.openRead("/f.bin", cancellation: nil)
            #expect(try reader.read(upToCount: 10)?.count == 10)
        }
        #expect(Wait.until { bench.requests.contains("4") })
    }

    /// A reader closed after its session was disconnected asks nothing.
    @Test
    internal func aReaderClosedAfterItsSessionAsksNothing() throws {
        let bench = try serving(.normal, NetworkFixSFTP.pattern(100_000))
        let session = bench.session()
        let reader = try session.openRead("/f.bin", cancellation: nil)
        #expect(try reader.read(upToCount: 10)?.count == 10)
        session.disconnect()
        reader.close()
        #expect(!bench.requests.contains("4"))
    }
}
