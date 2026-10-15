import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// An SFTP session against the test server, with a log and the requests the server saw.
///
/// Unchecked: the log is guarded by `lock`; the rest is set in `init`.
internal final class CovNetSFTPBench: @unchecked Sendable {
    /// The sandbox; the server's files are in `srv`.
    internal let box: Sandbox
    /// The test server.
    internal let server: FakeSFTPServer
    /// The environment of the sessions.
    internal let environment = SessionEnvironment()
    /// The address the sessions are for.
    internal let key = ServerKey(scheme: "sftp", host: "fake.invalid")
    private let lock = NSLock()
    private var lines: [String] = []

    /// What the session wrote into the log.
    internal var log: [String] { lock.withLock { lines } }

    /// The kinds of the requests the server saw, in order.
    internal var requests: [String] {
        ((try? String(contentsOf: box.url("sftp-requests.log"), encoding: .utf8)) ?? "").split(separator: "\n")
            .map(String.init)
    }

    /// A server in `mode`, with requests that may take `timeout` seconds.
    internal init(mode: FakeSFTPServer.Mode, timeout: TimeInterval) throws {
        box = try Sandbox()
        try box.folder("srv")
        server = try FakeSFTPServer(root: box.url("srv"), box: box, mode: mode, delay: 1...5)
        var values = NetworkOptions.Values()
        values.timeout = timeout
        environment.options.values = values
        environment.log = { [weak self] line in self?.lock.withLock { self?.lines.append(line) } }
    }

    /// A server in `mode`, with requests that may take ten seconds.
    internal convenience init(mode: FakeSFTPServer.Mode) throws {
        try self.init(mode: mode, timeout: 10)
    }

    /// A plain server, with requests that may take `timeout` seconds.
    internal convenience init(timeout: TimeInterval) throws {
        try self.init(mode: .normal, timeout: timeout)
    }

    /// A plain server, with requests that may take ten seconds.
    internal convenience init() throws {
        try self.init(mode: .normal, timeout: 10)
    }

    /// A session for `profile` over `transport`.
    internal func session(_ profile: ConnectionProfile, transport: SFTPTransport) -> SFTPSession {
        SFTPSession(profile: profile, environment: environment, transport: transport)
    }

    /// A session for `profile` with the server.
    internal func session(_ profile: ConnectionProfile) -> SFTPSession {
        session(profile, transport: server.transport)
    }

    /// A session for the bench's address over `transport`.
    internal func session(transport: SFTPTransport) -> SFTPSession {
        session(ConnectionProfile(key: key), transport: transport)
    }

    /// A session for the bench's address with the server.
    internal func session() -> SFTPSession {
        session(ConnectionProfile(key: key), transport: server.transport)
    }

    /// A transport that runs `shell` (where `$SSH_ASKPASS` asks the session's questions) and then the server.
    internal func asking(_ shell: String) throws -> SFTPTransport {
        let url = box.url("asking.sh")
        let start = ([server.transport.executable] + server.transport.arguments).map { "'\($0)'" }
        try "\(shell)\nexec \(start.joined(separator: " "))\n".write(to: url, atomically: true, encoding: .utf8)
        return SFTPTransport(executable: "/bin/sh", arguments: [url.path], asksQuestions: true)
    }

    /// A link at `path` in the server's folder that points to `target`.
    internal func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: box.url("srv/\(path)").path, withDestinationPath: target)
    }

    deinit {
        // Nothing to release.
    }
}
