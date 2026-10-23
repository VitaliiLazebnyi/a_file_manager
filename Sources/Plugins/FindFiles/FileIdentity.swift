import Foundation

/// Which file a local path really is: the device and inode, which are the same for a hard
/// link, and for a folder reached by two roads (macOS shows the data volume both directly and
/// under /System/Volumes/Data).
internal struct FileIdentity: Hashable {
    /// `SF_DATALESS` of `st_flags`: a file whose contents are not on this disk (iCloud Drive
    /// with optimised storage); reading it downloads it.
    internal static let datalessFlag: UInt32 = 0x4000_0000

    /// The device (disk) the file is on, as `st_dev`.
    internal let device: UInt64
    /// The file's number on its device, as `st_ino`.
    internal let inode: UInt64

    /// What a local path is, with one system call; nil for other locations or a path that
    /// cannot be examined.
    ///
    /// Links are followed.
    internal static func of(_ url: URL) -> (identity: Self, isRegularFile: Bool)? {
        guard let info = status(of: url) else {
            return nil
        }
        return (
            Self(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino)),
            info.st_mode & S_IFMT == S_IFREG
        )
    }

    private static func status(of url: URL) -> stat? {
        guard url.isFileURL else {
            return nil
        }
        var info = stat()
        return stat(url.path, &info) == 0 ? info : nil
    }

    /// False for a FIFO, a device or a socket, which would block or never end when read, and
    /// for a file that is only a stub of one in the cloud (reading it would download it, for
    /// every file of a search).
    ///
    /// A location that is not a local path is given the benefit of the doubt.
    internal static func canBeRead(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return true
        }
        guard let info = status(of: url) else {
            return false
        }
        return info.st_mode & S_IFMT == S_IFREG && info.st_flags & datalessFlag == 0
    }
}
