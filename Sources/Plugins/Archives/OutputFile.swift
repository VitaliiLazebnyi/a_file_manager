import AFMKernel
import Foundation

/// A new file on the local disk, written from front to back, with the possibility to go back
/// and correct a header.
///
/// Used by one thread.
internal final class OutputFile {
    /// Where the file lies.
    internal let url: URL
    private let descriptor: Int32
    private var buffer = Data()
    private var flushed: UInt64 = 0
    private var isClosed = false

    /// Where the next byte goes.
    internal var position: UInt64 { flushed + UInt64(buffer.count) }

    /// Creates the file at `url` with the rights `mode`; the file must not exist yet.
    ///
    /// It is the user's alone until whoever writes it says otherwise (`setMode`): a half-written
    /// archive is nobody else's to read.
    internal init(creating url: URL, mode: mode_t) throws {
        self.url = url
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? FileSystemError.alreadyExists(url.path) : posixError(errno, url.path)
        }
    }

    /// Continues an existing file at `offset`; what the file held from there on is cut off.
    internal init(extending url: URL, from offset: UInt64) throws {
        self.url = url
        // Opened without waiting and through no link, and looked at before anything is written:
        // whatever has taken the file's name meanwhile (a pipe, which would hold the open for
        // good or end the program at the first write to it, a link) is refused.
        descriptor = open(url.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(errno, url.path) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw posixError(EINVAL, url.path)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        guard let start = off_t(exactly: offset), ftruncate(descriptor, start) == 0,
            lseek(descriptor, start, SEEK_SET) >= 0
        else {
            let code = errno
            Darwin.close(descriptor)
            throw posixError(code, url.path)
        }
        flushed = offset
    }

    /// The rights of the file, whatever the process's mask says.
    internal func setMode(_ mode: mode_t) {
        if !isClosed { fchmod(descriptor, mode & 0o7777) }
    }

    /// Gives up what was written: the room it took is free at once, not when the file goes.
    internal func discard() {
        buffer.removeAll()
        if !isClosed { ftruncate(descriptor, 0) }
    }

    /// Appends `data`; small blocks are gathered and written together.
    internal func write(_ data: Data) throws {
        if data.count >= 1 << 16 {
            try flush()
            try writeOut(data, at: nil)
            flushed += UInt64(data.count)
        } else {
            buffer.append(data)
            if buffer.count >= 1 << 16 { try flush() }
        }
    }

    /// Replaces bytes that were written before.
    internal func rewrite(_ data: Data, at offset: UInt64) throws {
        try flush()
        try writeOut(data, at: offset)
    }

    private func flush() throws {
        guard !buffer.isEmpty else {
            return
        }
        try writeOut(buffer, at: nil)
        flushed += UInt64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    private func writeOut(_ data: Data, at offset: UInt64?) throws {
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let put = retryingInterrupted {
                    let from = bytes.baseAddress?.advanced(by: done)
                    let left = bytes.count - done
                    if let offset {
                        return pwrite(descriptor, from, left, off_t(offset) + off_t(done))
                    }
                    return Darwin.write(descriptor, from, left)
                }
                if put < 0 { throw posixError(errno, url.path) }
                done += put
            }
        }
    }

    /// Writes out what is gathered and closes the file; once only, later calls do nothing.
    ///
    /// `durably` returns only when the disk holds the data: for a file that is about to take
    /// the place of another, which a rename after a loss of power must not leave half-written.
    internal func close(durably: Bool) throws {
        guard !isClosed else {
            return
        }
        try flush()
        if durably, !Durable.sync(descriptor) {
            let code = errno
            isClosed = true
            Darwin.close(descriptor)
            throw posixError(code, url.path)
        }
        isClosed = true
        if Darwin.close(descriptor) != 0 { throw posixError(errno, url.path) }
    }

    deinit {
        if !isClosed { Darwin.close(descriptor) }
    }
}
