public import AFMKernel
public import Foundation

/// Mounting and ejecting network volumes, the Mac's form of mapping and disconnecting network
/// drives (spec 11 › Windows network functions).
///
/// Both calls block and are made from a job.
public protocol VolumeMounter: AnyObject, Sendable {
    /// Mounts the share at `url` (smb, afp, nfs, http/https for WebDAV) and returns where it
    /// appeared under /Volumes. The system asks for a name and password when it needs them.
    func mount(_ url: URL) throws -> [URL]
    /// `mount(_:)`, which ends early, by throwing, once `cancellation` is set.
    func mount(_ url: URL, cancellation: CancellationFlag) throws -> [URL]
    /// Ejects the volume mounted at `volume`.
    func unmount(_ volume: URL) throws
}

/// What every mounter can do the same way.
extension VolumeMounter {
    /// Checks `cancellation` once and then mounts without it, for a mounter that cannot take a request back.
    public func mount(_ url: URL, cancellation: CancellationFlag) throws -> [URL] {
        if cancellation.isCancelled { throw NetworkError.cancelled }
        return try mount(url)
    }
}
