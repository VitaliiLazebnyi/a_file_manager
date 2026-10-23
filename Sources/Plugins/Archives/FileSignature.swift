import Foundation

/// What identifies the state of a file on disk: when any of it changes, the file was rewritten.
internal struct FileSignature: Equatable {
    /// The size in bytes.
    internal let size: Int64
    /// The whole seconds of the time of the last change, since 1970.
    internal let seconds: Int
    /// The nanoseconds of that time.
    internal let nanoseconds: Int
    /// The file's number on its volume: a file put in the old one's place has another.
    internal let inode: UInt64

    /// The time of the last change.
    internal var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    /// The signature of a file as `stat` describes it.
    internal init(_ status: stat) {
        size = Int64(status.st_size)
        seconds = status.st_mtimespec.tv_sec
        nanoseconds = status.st_mtimespec.tv_nsec
        inode = UInt64(status.st_ino)
    }

    /// The signature of the file at a path; nil when there is none (or it cannot be asked).
    internal static func of(_ path: String) -> Self? {
        var status = stat()
        guard stat(path, &status) == 0 else {
            return nil
        }
        return Self(status)
    }
}
