import AFMKernel

@testable import NetworkPlugin

/// An FTP session against a scripted server, as a guest that was chosen, with requests that may take ten seconds and
/// no keep-alive unless the options say otherwise.
internal final class CovNetFTPBench {
    /// The scripted server.
    internal let server: CoverageNetworkServer
    /// The center of the sessions.
    internal let center: ConnectionCenter

    /// The address of the server.
    internal var key: ServerKey { server.key }
    /// What the session asks through.
    internal var environment: SessionEnvironment { center.environment }

    /// A bench whose server runs `script`, with the options `change` makes.
    internal init(
        options change: (inout NetworkOptions.Values) -> Void,
        script: @escaping CoverageNetworkServer.Script
    ) throws {
        server = try CoverageNetworkServer(script: script)
        center = server.center(change)
    }

    /// The session of the server.
    internal func session() throws -> FTPSession {
        guard let session = try center.session(for: key) as? FTPSession else {
            throw FileSystemError.notSupported("not an FTP session")
        }
        return session
    }

    /// The commands the server received that start with `prefix`.
    internal func commands(_ prefix: String) -> [String] {
        server.commands.filter { $0.hasPrefix(prefix) }
    }

    deinit {
        center.disconnectAll()
        server.stop()
    }
}
