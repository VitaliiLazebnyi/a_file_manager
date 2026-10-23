import Foundation

@testable import NetworkPlugin

/// Stands in for the system when volumes are mounted: every mount fails with a message that
/// names the server, as the system's does.
internal final class RefusingMounter: VolumeMounter {
    /// Throws a `VolumeError` that names the address without its password.
    internal func mount(_ url: URL) throws -> [URL] {
        let server = ServerAddress.removingPassword(from: url.absoluteString)
        throw VolumeError(message: "The server \(server) could not be connected: no route.")
    }

    /// Does nothing: nothing was ever mounted.
    internal func unmount(_: URL) {
        // Nothing to eject.
    }

    deinit {
        // Nothing to release.
    }
}
