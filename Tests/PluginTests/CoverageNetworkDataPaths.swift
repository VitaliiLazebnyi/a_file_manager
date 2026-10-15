import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Data connections over IPv6 in active mode, and over TLS to a server that wants its session reused.
@Suite
internal struct CoverageNetworkDataPaths {
    /// In active mode over IPv6 the port is given with EPRT.
    @Test
    internal func activeModeOverIPv6UsesEPRT() throws {
        let listing = Data("-rw-r--r-- 1 u g 5 Jan 01 2020 six\r\n".utf8)
        let server = try CoverageNetworkServer(onIPv6: true, greeting: ["220 Six"]) { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "EPRT":
                line.send(line.connectBack(String(command.dropFirst(5))) ? "200 Connected" : "500 No")
                return .handled

            case "LIST":
                line.transfer(listing, verdict: "226 Done")
                return .handled

            default:
                return .standard
            }
        }
        let connection = server.connection { config in
            config.host = "::1"
            config.passive = false
        }
        try connection.connect()
        defer { connection.close() }
        var names: [String] = []
        try connection.list("/", showHidden: false) { entries in
            names += entries.map(\.name)
            return true
        }
        #expect(names == ["six"])
        #expect(server.commands.contains { $0.hasPrefix("EPRT |2|::1|") })
    }

    /// A server that wants the TLS session of the control connection reused says why it refuses.
    @Test(.enabled(if: TLSServer.isAvailable))
    internal func aServerThatWantsItsSessionReusedSaysSo() throws {
        let box = try Sandbox()
        try box.file("srv/a.txt", "a")
        let server = try TLSServer(mode: .explicit, box: box, requiresReuse: true)
        let trust = CertificateTrust()
        let config = FTPServerConfig(host: "127.0.0.1", port: server.port, tls: .explicit, timeout: 10)
        do {
            try FTPConnection(config: config, trust: trust).connect()
        } catch NetworkError.untrustedCertificate(let certificate) {
            trust.accept(certificate.fingerprint, for: "127.0.0.1")
        }
        let connection = FTPConnection(config: config, trust: trust)
        try connection.connect()
        defer { connection.close() }
        let error = #expect(throws: NetworkError.self) { try connection.beginTransfer("RETR /a.txt", type: "I") }
        guard case .sessionReuseRequired(let said) = error else {
            Issue.record("not about session reuse: \(String(describing: error))")
            return
        }
        #expect(said.hasPrefix("522"))
    }
}
