import AFMKernel
import Foundation

/// Which file a local path really is: the device and inode, which are the same for a hard
/// link, and for a folder reached by two roads (macOS shows the data volume both directly and
/// under /System/Volumes/Data).
struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    /// `SF_DATALESS` of `st_flags`: a file whose contents are not on this disk (iCloud Drive
    /// with optimised storage); reading it downloads it.
    static let datalessFlag: UInt32 = 0x4000_0000

    /// What a local path is, with one system call; nil for other locations or a path that
    /// cannot be examined. Links are followed unless `followingLinks` is off.
    static func of(_ url: URL, followingLinks: Bool = true) -> (identity: Self, isRegularFile: Bool)? {
        guard let info = status(of: url, followingLinks: followingLinks) else { return nil }
        return (
            Self(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino)),
            info.st_mode & S_IFMT == S_IFREG
        )
    }

    private static func status(of url: URL, followingLinks: Bool) -> stat? {
        guard url.isFileURL else { return nil }
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return followingLinks ? stat(path, &info) : lstat(path, &info)
        }
        return result == 0 ? info : nil
    }

    /// False for a FIFO, a device or a socket, which would block or never end when read, and
    /// for a file that is only a stub of one in the cloud (reading it would download it, for
    /// every file of a search). A location that is not a local path is given the benefit of the doubt.
    static func canBeRead(_ url: URL) -> Bool {
        guard url.isFileURL else { return true }
        guard let info = status(of: url, followingLinks: true) else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_flags & datalessFlag == 0
    }
}

/// Reads a local file through a descriptor that was checked after it was opened: the file is
/// opened without waiting (a FIFO that took the place of the file since it was looked at
/// would block an `open` for good), and only a regular file that is not a cloud stub is kept.
final class LocalFileReader: FileReader {
    private var descriptor: Int32
    private let lock = NSLock()

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Nil when the file cannot be opened or is not a plain file that is here.
    static func open(_ url: URL) -> LocalFileReader? {
        guard url.isFileURL else { return nil }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_flags & FileIdentity.datalessFlag == 0
        else {
            Darwin.close(descriptor)
            return nil
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
        return LocalFileReader(descriptor: descriptor)
    }

    func read(upToCount count: Int) throws -> Data? {
        lock.lock()
        let descriptor = self.descriptor
        lock.unlock()
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        var data = Data(count: max(count, 0))
        let got = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
            while true {
                let result = Darwin.read(descriptor, base, buffer.count)
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        if got < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if got == 0 { return nil }
        data.removeSubrange(got...)
        return data
    }

    func seek(to offset: UInt64) throws {
        lock.lock()
        let descriptor = self.descriptor
        lock.unlock()
        guard descriptor >= 0, let position = off_t(exactly: offset), lseek(descriptor, position, SEEK_SET) >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    func close() {
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func interrupt() {}

    deinit {
        close()
    }
}

extension FileSystemRegistry {
    /// A reader for a file a search or comparison is about to read through: local files by
    /// way of `LocalFileReader`, others through their file system.
    func searchReader(for url: URL, cancellation: CancellationFlag) -> any FileReader? {
        if url.isFileURL { return LocalFileReader.open(url) }
        return try? provider(for: url).read(url, cancellation: cancellation)
    }
}
