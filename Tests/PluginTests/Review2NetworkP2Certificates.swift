import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// A certificate check that takes long holds up neither its own stream nor another's (N057).
///
/// The check is made slow with a hook where it runs; the server is the local TLS test server.
@Suite(.enabled(if: TLSServer.isAvailable))
internal struct Review2NetworkP2Certificates {
    /// While one check is held, its stream's waits still end and other streams come to their verdicts.
    @Test
    internal func aSlowCheckHoldsUpNeitherItsOwnStreamNorAnother() throws {
        let box = try Sandbox()
        try box.folder("srv")
        let server = try TLSServer(mode: .implicit, box: box)
        defer { server.stop() }

        // The first connection's certificate check is held until the test lets go.
        let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        let slow = TLSSettings(host: "127.0.0.1", trust: CertificateTrust()) {
            entered.signal()
            release.wait()
        }
        let first = NetStream(host: "127.0.0.1", port: server.port, security: .tls(slow))
        first.start()
        defer { first.close() }
        #expect(entered.wait(timeout: .now() + Wait.ceiling) == .success)

        // Its own stream still serves its waits: a time limit and a flag both end them while
        // the check sits there. (They would not if the check ran on the stream's queue.)
        #expect(throws: NetworkError.self) { try first.waitUntilReady(timeout: 0.3, cancellation: nil) }
        let flag = CancellationFlag()
        let waiting = AdoptOutcome { try first.waitUntilReady(timeout: 600, cancellation: flag) }
        #expect(!waiting.ended(within: 0.3))
        flag.cancel()
        #expect(waiting.ended() && waiting.failed)

        // Other connections are checked meanwhile, several at once: each comes to its verdict
        // (the certificate is self-signed, so each is refused and remembered for the question).
        let others = (0..<3).map { _ in TLSSettings(host: "127.0.0.1", trust: CertificateTrust()) }
        let streams = others.map { NetStream(host: "127.0.0.1", port: server.port, security: .tls($0)) }
        for stream in streams {
            stream.start()
        }
        defer {
            for stream in streams {
                stream.close()
            }
        }
        for (settings, stream) in zip(others, streams) {
            #expect(throws: NetworkError.self) { try stream.waitUntilReady(timeout: 120, cancellation: nil) }
            #expect(settings.rejected?.subject.contains("localhost") == true)
        }
        #expect(slow.rejected == nil, "the held check came to a verdict")

        // Let go, the first check ends like the others.
        release.signal()
        #expect(adoptWait { slow.rejected != nil })
    }
}
