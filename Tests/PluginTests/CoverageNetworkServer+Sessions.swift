import AFMKernel
import Foundation

@testable import NetworkPlugin

/// FTP sessions on the scripted server.
extension CoverageNetworkServer {
    /// The key of this server.
    internal var key: ServerKey { ServerKey(scheme: "ftp", host: "127.0.0.1", port: port) }

    /// A center whose FTP sessions reach this server as a guest that was chosen; `change`
    /// adjusts the options.
    internal func center(_ change: (inout NetworkOptions.Values) -> Void) -> ConnectionCenter {
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 10
        values.keepAliveInterval = 0
        change(&values)
        environment.options.values = values
        environment.declineMemory = 0
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        center.announce(ConnectionProfile(key: key, anonymous: true), chosen: true)
        return center
    }

    /// The FTP session of this server, with the usual options.
    internal func session() throws -> any RemoteSession {
        try center { _ in
            // The usual options.
        }
        .session(for: key)
    }
}
