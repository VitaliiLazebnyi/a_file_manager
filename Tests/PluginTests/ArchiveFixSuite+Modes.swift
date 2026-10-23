import Foundation

/// What the disk says of a file itself, links not followed.
extension ArchiveFixSuite {
    /// The permission bits of the file at `url` (a link's own, not its target's); -1 when there is none.
    internal func permissionBits(_ url: URL) -> Int {
        var status = stat()
        return lstat(url.path, &status) == 0 ? Int(status.st_mode & 0o7777) : -1
    }

    /// Whether a symbolic link stands at `url`.
    internal func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
    }
}
