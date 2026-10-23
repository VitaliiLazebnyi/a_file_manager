import Foundation
import NetworkPlugin

/// Stands in for the system when volumes are mounted and ejected.
///
/// Unchecked: its switches are set by the test before use, and it is used from one thread at a
/// time.
internal final class FakeMounter: VolumeMounter, @unchecked Sendable {
    /// The addresses mounted, in order.
    internal var mounted: [URL] = []
    /// The volumes ejected, in order.
    internal var ejected: [URL] = []
    /// The folder a mount gives.
    internal var mountPoint = URL(fileURLWithPath: "/")
    /// When set, what every mount throws.
    internal var failure: (any Error)?

    /// Records the address and gives the mount point, or throws the failure.
    internal func mount(_ url: URL) throws -> [URL] {
        if let failure {
            throw failure
        }
        mounted.append(url)
        return [mountPoint]
    }

    /// Records the volume.
    internal func unmount(_ volume: URL) {
        ejected.append(volume)
    }

    deinit {
        // Nothing to release.
    }
}
