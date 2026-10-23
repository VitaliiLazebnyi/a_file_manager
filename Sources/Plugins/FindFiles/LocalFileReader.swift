import AFMKernel
import Foundation

/// Reads a local file through a descriptor that was checked after it was opened: the file is
/// opened without waiting (a FIFO that took the place of the file since it was looked at
/// would block an `open` for good), and only a regular file that is not a cloud stub is kept.
///
/// The descriptor is guarded by `lock`; it is used outside the lock, which is safe because a
/// `FileReader` is used by one thread at a time (`close` too) and `interrupt` does nothing.
internal final class LocalFileReader: FileReader, @unchecked Sendable {
    /// Reads from a descriptor into a buffer, as `read(2)` does, setting `errno` when it fails.
    internal typealias SystemRead = @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int

    private var descriptor: Int32
    private let lock = NSLock()
    private let systemRead: SystemRead

    private init(descriptor: Int32, systemRead: @escaping SystemRead) {
        self.descriptor = descriptor
        self.systemRead = systemRead
    }

    /// A reader of `url` that reads with the system's `read`; nil when the file cannot be opened or is not a
    /// plain file that is here.
    internal static func open(_ url: URL) -> LocalFileReader? {
        open(url) { Darwin.read($0, $1, $2) }
    }

    /// A reader of `url`; nil when the file cannot be opened or is not a plain file that is here.
    ///
    /// `systemRead` does the reading: the system's `read`, unless a test stands in for the disk.
    internal static func open(_ url: URL, systemRead: @escaping SystemRead) -> LocalFileReader? {
        guard url.isFileURL else {
            return nil
        }
        let opened = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else {
            return nil
        }
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_flags & FileIdentity.datalessFlag == 0
        else {
            Darwin.close(opened)
            return nil
        }
        let flags = fcntl(opened, F_GETFL)
        if flags >= 0 {
            _ = fcntl(opened, F_SETFL, flags & ~O_NONBLOCK)
        }
        return LocalFileReader(descriptor: opened, systemRead: systemRead)
    }

    /// Up to `count` bytes from where the reader stands; nil at the end of the file.
    ///
    /// Throws when the reader is closed or the system cannot read; a read cut short by a signal is tried again.
    internal func read(upToCount count: Int) throws -> Data? {
        let current = currentDescriptor()
        guard current >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        var data = Data(count: max(count, 0))
        let got = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                return 0
            }
            var result: Int
            repeat {
                result = systemRead(current, base, buffer.count)
            } while result < 0 && errno == EINTR
            return result
        }
        if got < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if got == 0 {
            return nil
        }
        data.removeSubrange(got...)
        return data
    }

    /// Moves the reader to `offset` bytes from the start of the file.
    ///
    /// Throws when the reader is closed or the offset cannot be reached.
    internal func seek(to offset: UInt64) throws {
        let current = currentDescriptor()
        guard current >= 0, let position = off_t(exactly: offset), lseek(current, position, SEEK_SET) >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    /// Closes the file; later reads throw.
    ///
    /// A second call does nothing.
    internal func close() {
        lock.lock()
        let closing = descriptor
        descriptor = -1
        lock.unlock()
        if closing >= 0 {
            Darwin.close(closing)
        }
    }

    /// Does nothing: a read of a local regular file does not block for long.
    internal func interrupt() {
        // Nothing waits that could be woken.
    }

    /// The descriptor as it is now (-1 once closed), read under the lock.
    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    deinit {
        close()
    }
}
