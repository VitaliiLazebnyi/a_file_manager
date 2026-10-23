import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Certificates the system does not trust, on logins of an FTP session over TLS.
@Suite(.enabled(if: TLSServer.isAvailable))
internal struct CovNetFTPCertificates {
    private let box: Sandbox
    private let server: TLSServer
    private let environment = SessionEnvironment()
    private let center: ConnectionCenter

    /// The address of the server.
    private var key: ServerKey { ServerKey(scheme: "ftps", host: "127.0.0.1", port: server.port) }

    /// A server with implicit TLS on a sandbox, and a center whose sessions may open three connections.
    internal init() throws {
        box = try Sandbox()
        try box.folder("srv")
        server = try TLSServer(
            mode: .implicit,
            box: box,
            refusesProtection: false,
            requiresReuse: false,
            resumesSessions: false
        )
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval, values.parallelConnections) = (10, 0, 3)
        environment.options.values = values
        center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        center.announce(ConnectionProfile(key: key, tls: .implicit, anonymous: true), chosen: true)
    }

    /// How many connections the server saw go wrong.
    private static func failures(in box: Sandbox) -> Int {
        (box.read("tls-errors.log") ?? "").split(separator: "\n").filter { $0.hasPrefix("error") }.count
    }

    /// A certificate that stays untrusted although the user accepts it is given up after three answers.
    @Test
    internal func aCertificateThatStaysUntrustedIsGivenUp() {
        defer { server.stop() }
        let questions = CovNetCount()
        environment.askToTrust = { _, _ in
            questions.add()
            return true
        }
        let error = #expect(throws: NetworkError.self) { _ = try center.connect(key, cancellation: nil) }
        #expect(CovNetErrorKind(error) == .untrustedCertificate)
        #expect(questions.value == 3)
    }

    /// A changed certificate that another login of the session accepted meanwhile is not asked about again.
    @Test
    internal func aCertificateAnotherLoginAcceptedIsNotAskedAboutAgain() throws {
        defer {
            center.disconnectAll()
            server.stop()
        }
        try NetworkFixSFTP.pattern(8_000_000).write(to: box.url("srv/big.bin"))
        environment.askToTrust = { [trust = environment.trust] profile, certificate in
            trust.accept(certificate.fingerprint, for: profile.key.host)
            return true
        }
        let (changes, before) = (CovNetCount(), Signal<Int>())
        environment.askToTrustChanged = { [trust = environment.trust, box] profile, certificate, _ in
            changes.add()
            // Answered once the other login, too, found the certificate changed.
            let base = before.wait() ?? 0
            _ = Wait.until { Self.failures(in: box) >= base + 2 }
            trust.replace(with: certificate.fingerprint, for: profile.key.host)
            return true
        }
        let session = try center.session(for: key)
        // A download that holds the first connection.
        let first = try session.openRead("/big.bin", cancellation: nil)
        defer { first.close() }
        #expect(try first.read(upToCount: 10)?.count == 10)
        // The certificate is not the one accepted any more: as if it had changed.
        before.set(Self.failures(in: box))
        environment.trust.replace(with: "00:00", for: key.host)
        let others = (0..<2)
            .map { _ in
                AdoptOutcome {
                    let reader = try session.openRead("/big.bin", cancellation: nil)
                    defer { reader.close() }
                    _ = try reader.read(upToCount: 10)
                }
            }
        #expect(others.allSatisfy { $0.ended() && !$0.failed })
        #expect(changes.value == 1)
    }
}
