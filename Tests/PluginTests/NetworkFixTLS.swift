import AFMKernel
import Foundation
import Security
import TestSupport
import Testing

@testable import NetworkPlugin

/// TLS: the data connections must be protected, and a certificate must be good for an address.
@Suite(.enabled(if: TLSServer.isAvailable))
internal struct NetworkFixTLS {
    /// A server that refuses PROT P is not used: the listing fails with an error that says so.
    @Test
    internal func aServerThatRefusesToProtectItsDataIsNotUsed() throws {
        let box = try Sandbox()
        try box.file("srv/hello.txt", "hello")
        let server = try TLSServer(
            mode: .explicit,
            box: box,
            refusesProtection: true,
            requiresReuse: false,
            resumesSessions: true
        )
        defer { server.stop() }
        let environment = SessionEnvironment()
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (10, 0)
        environment.options.values = values
        environment.askToTrust = { [trust = environment.trust] profile, certificate in
            trust.accept(certificate.fingerprint, for: profile.key.host)
            return true
        }
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: center)
        let key = ServerKey(scheme: "ftps", host: "127.0.0.1", port: server.port)
        center.announce(ConnectionProfile(key: key, tls: .explicit, anonymous: true))
        defer { center.disconnectAll() }
        do {
            _ = try fileSystem.list(key.url(), showHidden: true)
            Issue.record("the listing went through without protection")
        } catch let error as NetworkError {
            if case .unexpected(let text) = error {
                #expect(text.contains("PROT P") && text.contains("unprotected"))
            } else {
                Issue.record("\(error)")
            }
        }
        #expect(!center.isConnected(key))
    }

    /// A self-signed certificate for an address, made with the system's openssl.
    private func certificate(altNames: String, in box: Sandbox) throws -> SecCertificate {
        let (pem, der) = (box.url("san.pem"), box.url("san.der"))
        let make = Process()
        make.executableURL = URL(fileURLWithPath: TLSServer.openssl)
        make.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", box.url("san.key").path, "-out", pem.path,
            "-days", "2",
            "-subj", "/CN=nobody", "-addext", "subjectAltName=\(altNames)", "-addext", "extendedKeyUsage=serverAuth",
            "-addext", "basicConstraints=critical,CA:FALSE"
        ]
        (make.standardOutput, make.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        try make.run()
        make.waitUntilExit()
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: TLSServer.openssl)
        convert.arguments = ["x509", "-in", pem.path, "-outform", "der", "-out", der.path]
        try convert.run()
        convert.waitUntilExit()
        return try #require(SecCertificateCreateWithData(nil, try Data(contentsOf: der) as CFData))
    }

    private func chain(of certificate: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust)
        let created = try #require(trust)
        // The certificate vouches for itself, so that only the name is in question.
        SecTrustSetAnchorCertificates(created, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(created, true)
        return created
    }

    /// A certificate is good only for the addresses and names it lists, unless the user accepted it for
    /// another address.
    @Test
    internal func anAddressMustBeAmongTheCertificatesAddresses() throws {
        let box = try Sandbox()
        let certificate = try certificate(altNames: "IP:127.0.0.1,DNS:named.example", in: box)

        let right = TLSSettings(host: "127.0.0.1", trust: CertificateTrust())
        #expect(right.evaluate(try chain(of: certificate)))
        #expect(right.rejected == nil)

        // Another address is not covered by the certificate, however valid the chain is.
        let trust = CertificateTrust()
        let wrong = TLSSettings(host: "127.0.0.2", trust: trust)
        #expect(!wrong.evaluate(try chain(of: certificate)))
        let shown = try #require(wrong.rejected)
        // The user is asked, and a certificate accepted for that address is good from then on.
        trust.accept(shown.fingerprint, for: "127.0.0.2")
        #expect(wrong.evaluate(try chain(of: certificate)))
        #expect(!TLSSettings(host: "127.0.0.3", trust: trust).evaluate(try chain(of: certificate)))

        // Names are checked as before.
        #expect(TLSSettings(host: "named.example", trust: CertificateTrust()).evaluate(try chain(of: certificate)))
        #expect(!TLSSettings(host: "other.example", trust: CertificateTrust()).evaluate(try chain(of: certificate)))
    }
}
