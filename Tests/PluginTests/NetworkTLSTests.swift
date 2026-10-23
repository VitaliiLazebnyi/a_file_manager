import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// FTP over TLS against a server with a self-signed certificate.
///
/// The in-process test server speaks no TLS, so this one is a short script for the Python that
/// comes with the developer tools, with a certificate made by `/usr/bin/openssl` in the sandbox;
/// where one of the two is missing the tests are skipped.
@Suite(.enabled(if: TLSServer.isAvailable))
internal struct NetworkTLSTests {
    /// In both modes the untrusted certificate is asked about once, No ends the connection, Yes lists the folder and
    /// moves files both ways over encrypted data connections, and is not asked about again.
    @Test(arguments: [TLSMode.explicit, .implicit])
    internal func connectsListsAndTransfers(mode: TLSMode) throws {
        let box = try Sandbox()
        try box.file("srv/hello.txt", "hello over TLS")
        let server = try TLSServer(mode: mode, box: box)
        defer { server.stop() }

        let environment = SessionEnvironment()
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (10, 0)
        environment.options.values = values
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: center)
        let key = ServerKey(scheme: "ftps", host: "127.0.0.1", port: server.port)
        center.announce(ConnectionProfile(key: key, tls: mode, anonymous: true))
        defer { center.disconnectAll() }

        // The certificate is signed by nobody the system knows: the user is asked, and No ends it.
        nonisolated(unsafe) var shown: [CertificateInfo] = []
        let accepts = Shared(false)
        environment.askToTrust = { [trust = environment.trust] profile, certificate in
            shown.append(certificate)
            if accepts.value { trust.accept(certificate.fingerprint, for: profile.key.host) }
            return accepts.value
        }
        #expect(throws: NetworkError.self) { try fileSystem.list(key.url(), showHidden: true) }
        #expect(shown.count == 1 && shown[0].subject.contains("localhost") && shown[0].fingerprint.count == 95)
        #expect(!center.isConnected(key))

        accepts.value = true
        #expect(try fileSystem.list(key.url(), showHidden: true).map(\.name) == ["hello.txt"])
        #expect(shown.count == 2)
        // Data connections are encrypted as well (PROT P), in both directions.
        let reader = try fileSystem.read(key.url(path: "/hello.txt"))
        #expect(try reader.read(upToCount: 100) == Data("hello over TLS".utf8))
        #expect(try reader.read(upToCount: 100) == nil)
        reader.close()
        let content = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let session = try center.session(for: key)
        let writer = try session.openWrite("/up.bin")
        try writer.write(content)
        try writer.close(attributes: FileAttributes())
        let stored = try Data(contentsOf: box.url("srv/up.bin"))
        #expect(stored == content)
        // Once accepted, the certificate is not asked about again, on any connection.
        #expect(shown.count == 2)
    }

    /// A server that speaks no TLS answers AUTH TLS with an error, and nothing more is sent to it.
    @Test
    internal func aServerWithoutTLSRefusesExplicitTLS() throws {
        let fixture = try FTPFixture()
        let key = ServerKey(scheme: "ftps", host: "127.0.0.1", port: fixture.server.port)
        fixture.center.announce(ConnectionProfile(key: key, tls: .explicit, anonymous: true))
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: fixture.center)
        #expect(throws: NetworkError.self) { try fileSystem.list(key.url(), showHidden: true) }
        #expect(fixture.server.commands == ["AUTH TLS"])
    }
}
