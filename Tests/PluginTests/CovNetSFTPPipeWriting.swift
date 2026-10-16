import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Writing a packet into a pipe that does not block.
@Suite
internal struct CovNetSFTPPipeWriting {
    private let reading: Int32
    private let writing: Int32

    /// A pipe whose write end does not block and raises no signal, filled up to the last byte.
    internal init() throws {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            throw POSIXError(.EMFILE)
        }
        (reading, writing) = (ends[0], ends[1])
        _ = fcntl(writing, F_SETNOSIGPIPE, 1)
        _ = fcntl(writing, F_SETFL, fcntl(writing, F_GETFL) | O_NONBLOCK)
        let block = [UInt8](repeating: 7, count: 4_096)
        while Darwin.write(writing, block, block.count) > 0 {
            // Until the pipe takes no more.
        }
        while Darwin.write(writing, block, 1) > 0 {
            // Up to the last byte.
        }
    }

    private func write(_ packet: Data, timeout: TimeInterval = 60, flag: CancellationFlag? = nil, closed: Bool = false)
        throws
    {
        try SFTPChannel.writeAll(packet, to: writing, writeTimeout: timeout, cancellation: flag) { closed }
    }

    private func close() {
        Darwin.close(reading)
        Darwin.close(writing)
    }

    /// A cancelled writer that has not written a byte of its packet stops at once.
    @Test
    internal func aCancelledWriterStopsBeforeTheFirstByte() {
        defer { close() }
        let flag = CancellationFlag()
        flag.cancel()
        #expect(
            CovNetErrorKind(#expect(throws: NetworkError.self) { try write(Data(count: 10), flag: flag) }) == .cancelled
        )
    }

    /// A writer stops when the channel was closed meanwhile.
    @Test
    internal func aWriterStopsWhenTheChannelIsClosed() {
        defer { close() }
        let error = #expect(throws: NetworkError.self) { try write(Data(count: 10), closed: true) }
        #expect(CovNetErrorKind(error) == .connectionLost)
    }

    /// A pipe that takes nothing for the whole time a write may take is given up.
    @Test
    internal func aPipeThatTakesNothingIsGivenUp() {
        defer { close() }
        let error = #expect(throws: NetworkError.self) { try write(Data(count: 10), timeout: 0.3) }
        #expect(CovNetErrorKind(error) == .timedOut)
    }

    /// A pipe nobody reads any more is a lost connection.
    @Test
    internal func aPipeNobodyReadsIsALostConnection() {
        Darwin.close(reading)
        defer { Darwin.close(writing) }
        let error = #expect(throws: NetworkError.self) { try write(Data(count: 10)) }
        #expect(CovNetErrorKind(error) == .connectionLost)
    }
}
