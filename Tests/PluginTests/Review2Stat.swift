import Foundation

/// What `lstat` says about an item of the local disk, for tests that check what a job left of it.
internal enum Review2Stat {
    /// The item's inode number; nil when there is no item.
    internal static func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// The item's permission bits with the three special ones; nil when there is no item.
    internal static func mode(_ url: URL) -> UInt16? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt16(info.st_mode & 0o7777) : nil
    }
}
