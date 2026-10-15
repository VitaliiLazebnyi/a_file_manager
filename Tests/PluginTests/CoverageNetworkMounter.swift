import Foundation
import NetworkPlugin

/// Stands in for the system when volumes are mounted and ejected: it records what it was asked
/// and answers as the test set it up.
///
/// Unchecked: everything is guarded by `lock`.
internal final class CoverageNetworkMounter: VolumeMounter, @unchecked Sendable {
    private let lock = NSLock()
    private var mountFailure: (any Error)?
    private var ejectFailure: (any Error)?
    private var volumes: [URL] = []
    private var mountedURLs: [URL] = []
    private var ejectedVolumes: [URL] = []

    /// The addresses that were mounted, in order.
    internal var mounted: [URL] { lock.withLock { mountedURLs } }
    /// The volumes that were ejected, in order.
    internal var ejected: [URL] { lock.withLock { ejectedVolumes } }

    /// A mounter that mounts nothing and ejects everything.
    internal init() {
        // Nothing set up yet.
    }

    /// Makes the next mounts throw `failure`.
    internal func failMounts(with failure: any Error) {
        lock.withLock { mountFailure = failure }
    }

    /// Makes the next ejects throw `failure`.
    internal func failEjects(with failure: any Error) {
        lock.withLock { ejectFailure = failure }
    }

    /// Makes the next mounts appear at `places`.
    internal func mountAt(_ places: [URL]) {
        lock.withLock { volumes = places }
    }

    /// Records the address and answers as set up.
    internal func mount(_ url: URL) throws -> [URL] {
        try lock.withLock {
            if let mountFailure {
                throw mountFailure
            }
            mountedURLs.append(url)
            return volumes
        }
    }

    /// Records the volume and answers as set up.
    internal func unmount(_ volume: URL) throws {
        try lock.withLock {
            if let ejectFailure {
                throw ejectFailure
            }
            ejectedVolumes.append(volume)
        }
    }

    deinit {
        // Nothing to release.
    }
}
