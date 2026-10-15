import AFMKernel
import Foundation

@testable import NetworkPlugin

/// The file system of the `ftp` scheme on a server in memory (`CoverageNetworkSession`), with
/// a clock the test moves.
internal struct CoverageNetworkMemoryServer {
    /// The server's key.
    internal let key = ServerKey(scheme: "ftp", host: "memory.invalid", port: 21)
    /// The clock of the remembered listings.
    internal let clock = CoverageNetworkClock()
    /// The connections.
    internal let center: ConnectionCenter
    /// The session of the server.
    internal let session: CoverageNetworkSession
    /// The file system.
    internal let fileSystem: RemoteFileSystem

    /// A server with `/docs/a.txt` (5 bytes) and the folder `/docs/sub`.
    internal init() {
        center = ConnectionCenter(environment: SessionEnvironment())
        let made = CoverageNetworkSession(profile: ConnectionProfile(key: key, anonymous: true))
        made.add("/docs", isDirectory: true, size: 0)
        made.add("/docs/a.txt", isDirectory: false, size: 5)
        made.add("/docs/sub", isDirectory: true, size: 0)
        session = made
        center.makeSession = { _, _ in made }
        let ticking = clock
        fileSystem = RemoteFileSystem(scheme: "ftp", center: center) { ticking.now }
    }

    /// The location of `path` on the server.
    internal func url(_ path: String) -> URL {
        key.url(path: path)
    }

    /// The names in a folder, as the file system lists them.
    internal func names(_ path: String) throws -> [String] {
        try fileSystem.list(url(path), showHidden: true).map(\.name)
    }
}
