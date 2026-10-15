import Foundation

/// What the local copies of the viewer need of the disk: the system's, or one a test makes full
/// or failing.
internal struct CopyDisk: Sendable {
    /// The disk of the temporary folder, and at most 1 GB a file.
    internal static let system = Self(
        freeSpace: freeSpace(of:),
        createFile: { open($0.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) },
        sizeLimit: 1 << 30
    )

    /// The bytes free for a program on the disk of a folder; nil when that cannot be told.
    internal var freeSpace: @Sendable (URL) -> Int64?
    /// Opens a new file for writing, failing when there is one; a negative number when it cannot.
    internal var createFile: @Sendable (URL) -> Int32
    /// The most that is copied for one file.
    internal var sizeLimit: Int64

    /// What `statfs` tells of the disk of `directory`.
    internal static func freeSpace(of directory: URL) -> Int64? {
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else {
            return nil
        }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}
