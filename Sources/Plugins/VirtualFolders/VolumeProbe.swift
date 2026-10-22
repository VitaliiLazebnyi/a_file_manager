import Foundation

/// What a branch walk asks the system about the disks under it: which disk and which entry of
/// it a folder is, whether a disk is mounted at a folder, and whether a walk from a folder goes
/// on to the firmlinked folders of other disks.
///
/// The walk decides with these alone where one volume ends; a test gives answers of its own.
internal struct VolumeProbe: Sendable {
    /// The answers of the system.
    internal static let system = Self(
        identity: { path, followsLinks in
            var info = stat()
            guard (followsLinks ? stat(path, &info) : lstat(path, &info)) == 0 else {
                return nil
            }
            return (info.st_dev, info.st_ino)
        },
        isMountPoint: { BranchWalker.isMountPoint($0) },
        crossesDisks: { $0 == "/" }
    )

    /// The disk and the entry of a path (a link followed, or not), nil when nothing is there.
    internal let identity: @Sendable (_ path: String, _ followsLinks: Bool) -> (device: dev_t, inode: ino_t)?
    /// Whether a disk is mounted at the path itself.
    internal let isMountPoint: @Sendable (String) -> Bool
    /// Whether a walk that starts at the path crosses onto other disks (the root does).
    internal let crossesDisks: @Sendable (String) -> Bool
}
