import AFMKernel
import Darwin
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// A stream whose connection is reset by the other side: the reads end with the error, whatever the moment the
/// reset arrives at.
@Suite
internal struct DetermNetStream {
    /// What arrived before a reset is read first, then the reads fail instead of ending.
    @Test
    internal func aConnectionThatIsResetFailsOnceWhatArrivedIsRead() throws {
        let listener = try TestFTPServer.listen()
        defer { close(listener) }
        let accepted = Signal<Int32>()
        OtherThread.start { accepted.set(accept(listener, nil, nil)) }
        let stream = NetStream(host: "127.0.0.1", port: TestFTPServer.port(of: listener))
        stream.start()
        defer { stream.close() }
        try stream.waitUntilReady(timeout: Wait.ceiling)
        let peer = try #require(accepted.wait())
        #expect(CoverageNetworkServer.sendAll(peer, Data("hello".utf8)))
        // Closed with a linger of nothing: the connection is reset, not ended.
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(peer, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(peer)
        var received = Data()
        var failure: (any Error)?
        while failure == nil {
            do {
                guard let piece = try stream.read(upToCount: 100, timeout: Wait.ceiling) else {
                    break
                }
                received += piece
            } catch {
                failure = error
            }
        }
        #expect(failure is NetworkError && Data("hello".utf8).starts(with: received))
    }
}
