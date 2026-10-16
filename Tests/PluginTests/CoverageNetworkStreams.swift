import AFMKernel
import Foundation
import Security
import TestSupport
import Testing

@testable import NetworkPlugin

/// Streams, listeners and certificates at the edges the other tests leave out.
@Suite
internal struct CoverageNetworkStreams {
    /// Runs the system's openssl with `arguments`.
    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TLSServer.openssl)
        process.arguments = arguments
        (process.standardOutput, process.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        try process.run()
        process.waitUntilExit()
    }

    /// A key made by hand from a host without a URL, for a scheme that is not a network scheme,
    /// gets a location on an FTP server that does not exist.
    @Test
    internal func anUnknownSchemeWithABadHostLeadsNowhere() {
        let key = ServerKey(scheme: "gopher", host: "no host")
        #expect(key.url(path: "/a b").absoluteString == "ftp://host.invalid/a%20b")
        #expect(ServerKey(scheme: "sftp", host: "no host").url().absoluteString == "sftp://host.invalid/")
    }

    /// Certificates accepted before are kept by server, whatever case the server's name had.
    @Test
    internal func acceptedCertificatesAreKeptByServerInAnyCase() {
        let trust = CertificateTrust(accepted: ["Files.Example": ["AA"], "files.example": ["BB"]])
        #expect(trust.isAccepted("AA", for: "FILES.example") && trust.isAccepted("BB", for: "files.example"))
        #expect(trust.fingerprints(for: "files.EXAMPLE") == ["AA", "BB"])
    }

    /// A stream knows no addresses before it is connected, nor after it was closed.
    @Test
    internal func aStreamKnowsNoAddressesWhenItIsNotConnected() {
        let stream = NetStream(host: "127.0.0.1", port: 9)
        #expect(stream.localAddress == nil && stream.remoteAddress == nil)
    }

    /// Sending to a peer that takes nothing ends at the time limit, and the stream is closed.
    @Test
    internal func sendingToAPeerThatTakesNothingEndsAtTheTimeLimit() throws {
        let listener = try TestFTPServer.listen()
        defer { close(listener) }
        let accepted = Signal<Int32>()
        OtherThread.start { accepted.set(accept(listener, nil, nil)) }
        let stream = NetStream(host: "127.0.0.1", port: TestFTPServer.port(of: listener))
        stream.start()
        defer { stream.close() }
        try stream.waitUntilReady(timeout: Wait.ceiling)
        let peer = try #require(accepted.wait())
        defer { close(peer) }
        // Nothing is read on the other side, so the buffers fill up and a piece is not taken in time.
        let block = Data(count: 1 << 20)
        var failure: NetworkError?
        for _ in 0..<4_096 where failure == nil {
            do {
                try stream.write(block, timeout: 0.5)
            } catch let error as NetworkError {
                failure = error
            }
        }
        #expect(CoverageNetworkServer.text(of: failure) == "sending")
        #expect(throws: NetworkError.self) { try stream.write(Data([1]), timeout: 1) }
    }

    /// A listener for an address this machine does not have listens on every address instead,
    /// and still lets the server in.
    @Test
    internal func aListenerForAnAddressOfAnotherMachineListensEverywhere() throws {
        let listener = try DataListener(peer: "127.0.0.1", local: "192.0.2.1")
        let port = try listener.start(timeout: 0.5)
        let client = NetStream(host: "127.0.0.1", port: port)
        client.start()
        defer { client.close() }
        let stream = try listener.accept(timeout: Wait.ceiling, cancellation: nil)
        try stream.waitUntilReady(timeout: Wait.ceiling)
        stream.close()
    }

    /// A transfer on a connection that was cut fails before anything more reaches the server.
    @Test(arguments: [false, true])
    internal func aTransferOnACutConnectionFails(passive: Bool) throws {
        let server = try CoverageNetworkServer(replies: ["PORT": "200 OK", "RETR": "550 No such file"])
        let connection = try server.connected { config in config.passive = passive }
        // The first transfer is refused; the type is set by then, and the connection is fine.
        let refused = #expect(throws: NetworkError.self) { try connection.beginTransfer("RETR /a", type: "I") }
        #expect(CoverageNetworkServer.code(of: refused) == 550 && connection.isUsable)
        let sent = server.commands.count
        connection.interrupt()
        #expect(throws: NetworkError.self) { try connection.beginTransfer("RETR /a", type: "I") }
        #expect(server.commands.count == sent)
    }

    /// The greeting before `AUTH TLS` may come in several lines, after a 120; a greeting that
    /// refuses the connection ends it before `AUTH TLS` is sent.
    @Test
    internal func greetingsBeforeExplicitTLS() throws {
        let slow = try CoverageNetworkServer(greeting: ["120 In a moment", "220-Welcome", "220 Ready"]) { _, _ in
            .standard
        }
        let refused = #expect(throws: NetworkError.self) { try slow.connected { $0.tls = .explicit } }
        #expect(CoverageNetworkServer.code(of: refused) == 502)
        #expect(slow.commands == ["AUTH TLS"])

        let busy = try CoverageNetworkServer(greeting: ["421 Too many users"]) { _, _ in .standard }
        let error = #expect(throws: NetworkError.self) { try busy.connected { $0.tls = .explicit } }
        #expect(CoverageNetworkServer.code(of: error) == 421)
        #expect(busy.commands.isEmpty)
    }

    /// A certificate without a subject is shown with an empty one.
    @Test(.enabled(if: TLSServer.isAvailable))
    internal func aCertificateWithoutASubjectIsShownWithAnEmptyOne() throws {
        let box = try Sandbox()
        let (pem, der) = (box.url("empty.pem"), box.url("empty.der"))
        try Self.openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", box.url("empty.key").path, "-out", pem.path,
            "-days", "2", "-subj", "/"
        ])
        try Self.openssl(["x509", "-in", pem.path, "-outform", "der", "-out", der.path])
        let certificate = try #require(SecCertificateCreateWithData(nil, try Data(contentsOf: der) as CFData))
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust)
        let settings = TLSSettings(host: "files.example", trust: CertificateTrust())
        #expect(!settings.evaluate(try #require(trust)))
        let shown = try #require(settings.rejected)
        #expect(shown.subject.isEmpty && !shown.problem.isEmpty && shown.fingerprint.count == 95)
    }

    /// A server reached by its name is asked for the certificate of that name.
    @Test(.enabled(if: TLSServer.isAvailable))
    internal func aServerReachedByNameIsCheckedForThatName() throws {
        let box = try Sandbox()
        try box.file("srv/hello.txt", "hello")
        let server = try TLSServer(mode: .implicit, box: box)
        defer { server.stop() }
        let environment = SessionEnvironment()
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (10, 0)
        environment.options.values = values
        let asked = Signal<CertificateInfo>()
        environment.askToTrust = { [trust = environment.trust] profile, certificate in
            asked.set(certificate)
            trust.accept(certificate.fingerprint, for: profile.key.host)
            return true
        }
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        let key = ServerKey(scheme: "ftps", host: "localhost", port: server.port)
        center.announce(ConnectionProfile(key: key, tls: .implicit, anonymous: true), chosen: true)
        defer { center.disconnectAll() }
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: center)
        #expect(try fileSystem.list(key.url(), showHidden: true).map(\.name) == ["hello.txt"])
        #expect(asked.wait()?.subject.contains("localhost") == true)
    }
}
