import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// A certificate that is not the one accepted before (review 2: N030, N031).
@Suite(.enabled(if: TLSServer.isAvailable))
internal struct Review2NetworkChangedCertificate {
    /// Another certificate for a known host asks its own question, and replaces the old one only when accepted.
    @Test
    internal func aChangedCertificateIsAQuestionOfItsOwn() throws {
        // Two servers with two certificates under one host name: the second is what the first
        // looks like to somebody in the middle.
        let (firstBox, secondBox) = (try Sandbox(), try Sandbox())
        try firstBox.file("srv/first.txt", "1")
        try secondBox.file("srv/second.txt", "2")
        let first = try TLSServer(mode: .implicit, box: firstBox)
        let second = try TLSServer(mode: .implicit, box: secondBox)
        defer {
            first.stop()
            second.stop()
        }

        let environment = SessionEnvironment()
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (10, 0)
        environment.options.values = values
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: center)
        defer { center.disconnectAll() }
        func key(_ server: TLSServer) -> ServerKey { ServerKey(scheme: "ftps", host: "127.0.0.1", port: server.port) }
        for server in [first, second] {
            center.announce(ConnectionProfile(key: key(server), tls: .implicit, anonymous: true), chosen: true)
        }

        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var firstUse: [String] = []
        nonisolated(unsafe) var changed: [(new: String, known: [String])] = []
        let acceptsChange = Shared(false)
        environment.askToTrust = { [trust = environment.trust] profile, certificate in
            firstUse.append(certificate.fingerprint)
            trust.accept(certificate.fingerprint, for: profile.key.host)
            return true
        }
        environment.askToTrustChanged = { [trust = environment.trust] profile, certificate, known in
            changed.append((certificate.fingerprint, known))
            if acceptsChange.value { trust.replace(with: certificate.fingerprint, for: profile.key.host) }
            return acceptsChange.value
        }
        #expect(try fileSystem.list(key(first).url(), showHidden: true).map(\.name) == ["first.txt"])
        #expect(firstUse.count == 1 && changed.isEmpty)

        // The other certificate for the same host: not the question of a first visit, and refused it stays refused.
        #expect(throws: NetworkError.self) { _ = try fileSystem.list(key(second).url(), showHidden: true) }
        #expect(firstUse.count == 1 && changed.count == 1)
        #expect(changed[0].known == [firstUse[0]] && changed[0].new != firstUse[0])
        #expect(environment.trust.fingerprints(for: "127.0.0.1") == [firstUse[0]])

        // Accepted knowingly, it takes the old one's place.
        acceptsChange.value = true
        #expect(try fileSystem.list(key(second).url(), showHidden: true).map(\.name) == ["second.txt"])
        #expect(environment.trust.fingerprints(for: "127.0.0.1") == [changed[1].new])
    }
}
