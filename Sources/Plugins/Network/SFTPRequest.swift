/// The request types of SFTP version 3.
internal enum SFTPRequest: UInt8 {
    /// Closes a handle.
    case close = 4
    /// A request named by a text: `posix-rename@openssh.com`.
    case extended = 200
    /// Sets attributes of an open file (its size, to cut it).
    case fsetstat = 10
    /// The attributes of an open file.
    case fstat = 8
    /// The attributes of a path, of the link itself where it is one.
    case lstat = 7
    /// Makes a directory.
    case mkdir = 14
    /// Opens a file.
    case open = 3
    /// Opens a directory for listing.
    case opendir = 11
    /// Reads bytes of an open file.
    case read = 5
    /// The next names of an open directory.
    case readdir = 12
    /// The absolute form of a path.
    case realpath = 16
    /// Removes a file.
    case remove = 13
    /// Renames; servers refuse when the destination exists.
    case rename = 18
    /// Removes an empty directory.
    case rmdir = 15
    /// Sets attributes of a path.
    case setstat = 9
    /// The attributes of a path, of a link's target where it is one.
    case stat = 17
    /// Writes bytes into an open file.
    case write = 6
}
