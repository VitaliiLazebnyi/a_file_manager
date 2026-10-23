import Foundation

/// Makes writes last through a loss of power.
internal enum Durable {
    /// Waits until the file's data is on the disk, in order (`F_BARRIERFSYNC`: what the file
    /// system needs to keep a rename behind it honest, without emptying the drive's cache as
    /// `F_FULLFSYNC` does).
    ///
    /// File systems that do not know it get a plain `fsync`.
    internal static func sync(_ descriptor: Int32) -> Bool {
        if fcntl(descriptor, F_BARRIERFSYNC) == 0 {
            return true
        }
        return fsync(descriptor) == 0
    }

    /// After a rename: the folder's entry is what makes the new file the file.
    internal static func syncFolder(of url: URL) {
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else {
            return
        }
        _ = fsync(descriptor)
        Darwin.close(descriptor)
    }

    /// Where a path leads once every symbolic link in it is followed: an archive that is
    /// reached through a link is rewritten where it really lies, and the link stays a link.
    internal static func realFile(_ url: URL) -> URL {
        guard let real = realpath(url.path, nil) else {
            return url
        }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: false)
    }
}
