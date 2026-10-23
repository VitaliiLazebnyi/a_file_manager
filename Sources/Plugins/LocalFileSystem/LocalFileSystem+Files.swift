public import AFMKernel
public import Foundation

/// Opening files to read, to write and to continue.
extension LocalFileSystem {
    /// Reads through the descriptor with `read(2)`, into a block that is the caller's own: no
    /// object of the system's is made per read, so nothing piles up on a long-lived thread.
    ///
    /// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` touches
    /// only `interruption`, which is safe from any thread.
    private final class Reader: FileReader, @unchecked Sendable {
        private var descriptor: Int32
        private let url: URL
        private let probes: LocalProbes
        private let interruption = Interruption()

        init(_ descriptor: Int32, url: URL, probes: LocalProbes) {
            (self.descriptor, self.url, self.probes) = (descriptor, url, probes)
        }

        func read(upToCount count: Int) throws -> Data? {
            guard descriptor >= 0 else { throw LocalFileSystem.posixError(EBADF, url) }
            guard count > 0 else {
                return nil
            }
            var data = Data(count: count)
            var code: Int32 = 0
            let file = descriptor
            let got = try data.withUnsafeMutableBytes { buffer in
                try interruption.run { () -> Int in
                    let got = probes.system("read", url.path) { Darwin.read(file, buffer.baseAddress, count) }
                    if got < 0 { code = errno }
                    return got
                }
            }
            guard got >= 0 else { throw LocalFileSystem.posixError(code, url) }
            guard got > 0 else {
                return nil
            }
            if got < count { data.removeSubrange(got...) }
            return data
        }

        func seek(to offset: UInt64) throws {
            guard descriptor >= 0 else { throw LocalFileSystem.posixError(EBADF, url) }
            guard let position = off_t(exactly: offset) else { throw LocalFileSystem.posixError(EINVAL, url) }
            // Setting the position of a regular file (all a reader reads) does not fail.
            lseek(descriptor, position, SEEK_SET)
        }

        func close() {
            guard descriptor >= 0 else {
                return
            }
            Darwin.close(descriptor)
            descriptor = -1
        }

        func interrupt() { interruption.interrupt() }

        deinit { close() }
    }

    /// Writes through the descriptor it was made with, and gives the file its date and its
    /// rights through the same descriptor before closing it: nothing that happens to the name
    /// meanwhile (a link put in its place) can redirect that.
    ///
    /// Unchecked: used by one thread at a time, as `FileWriter` allows; `interrupt` touches
    /// only `interruption`, which is safe from any thread.
    private final class Writer: FileWriter, @unchecked Sendable {
        private var descriptor: Int32
        private let url: URL
        /// What a new file is given when the caller names no rights; nil for a file that was
        /// there before (its rights stay as they are).
        private let defaultPermissions: mode_t?
        private let probes: LocalProbes
        private let interruption = Interruption()

        init(_ descriptor: Int32, url: URL, defaultPermissions: mode_t?, probes: LocalProbes) {
            (self.descriptor, self.url, self.defaultPermissions, self.probes) = (
                descriptor, url, defaultPermissions, probes
            )
        }

        func write(_ data: Data) throws {
            guard descriptor >= 0 else { throw LocalFileSystem.posixError(EBADF, url) }
            let file = descriptor
            try data.withUnsafeBytes { buffer in
                var done = 0
                while done < buffer.count {
                    var code: Int32 = 0
                    let wrote = try interruption.run { () -> Int in
                        let wrote = probes.system("write", url.path) {
                            Darwin.write(file, buffer.baseAddress?.advanced(by: done), buffer.count - done)
                        }
                        if wrote < 0 { code = errno }
                        return wrote
                    }
                    guard wrote >= 0 else { throw LocalFileSystem.posixError(code, url) }
                    done += wrote
                }
            }
        }

        func close(attributes: FileAttributes) throws {
            guard descriptor >= 0 else {
                return
            }
            var failure: (any Error)?
            if let modified = attributes.modified {
                let seconds = modified.timeIntervalSince1970.rounded(.down)
                let nanoseconds = ((modified.timeIntervalSince1970 - seconds) * 1e9).rounded(.down)
                // The time of access stays as it is.
                var times = [
                    timespec(tv_sec: 0, tv_nsec: Int((1 << 30) - 2)),
                    timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
                ]
                if probes.system("futimens", url.path, { futimens(descriptor, &times) }) != 0 {
                    failure = LocalFileSystem.posixError(errno, url)
                }
            }
            if let mode = attributes.permissions.map({ mode_t($0) & 0o7777 }) ?? defaultPermissions {
                if probes.system("fchmod", url.path, { fchmod(descriptor, mode) }) != 0, failure == nil {
                    failure = LocalFileSystem.posixError(errno, url)
                }
            }
            let result = probes.system("close", url.path) { Darwin.close(descriptor) }
            descriptor = -1
            if result != 0, failure == nil { failure = LocalFileSystem.posixError(errno, url) }
            if let failure { throw failure }
        }

        func interrupt() { interruption.interrupt() }

        deinit {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
    }

    /// The rights a new file gets when none are given: what `open` would have made with 0666,
    /// less the umask, which is read once (it can only be read by setting it).
    internal static let defaultFileMode: mode_t = {
        let mask = umask(0o022)
        umask(mask)
        return 0o644 & ~mask
    }()

    /// Opens the file for reading, without a flag to end the wait.
    public func read(_ url: URL) throws -> any FileReader {
        try read(url, cancellation: CancellationFlag())
    }

    /// Opened without waiting (`O_NONBLOCK`) and looked at before anything is read: a pipe or
    /// a device is refused with an error, where opening it would hang the caller.
    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        let descriptor = try openFile(url, O_RDONLY | O_NONBLOCK, mode: 0, cancellation: cancellation)
        try requireRegularFile(descriptor, url)
        return Reader(descriptor, url: url, probes: probes)
    }

    /// Makes a new file to write, without a flag to end the wait; an existing name is refused.
    public func write(_ url: URL) throws -> any FileWriter {
        try write(url, cancellation: CancellationFlag())
    }

    /// The file is made with the rights of its owner alone and gets the ones it is meant to
    /// have when it is closed: what is written is not readable by others while it arrives (a
    /// 0600 file streamed from an archive or a server), nor if the transfer fails half way.
    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        // O_EXCL: the name must be free, and an existing file is never opened for writing.
        let descriptor: Int32
        do {
            descriptor = try openFile(url, O_WRONLY | O_CREAT | O_EXCL, mode: 0o600, cancellation: cancellation)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            throw FileSystemError.alreadyExists(url.path)
        }
        return Writer(descriptor, url: url, defaultPermissions: Self.defaultFileMode, probes: probes)
    }

    /// The file is cut and the position set through the descriptor it was opened with, so
    /// nothing can come between.
    ///
    /// A link at the end of the name is not followed (it is reported), and neither is anything but
    /// a regular file opened: a pipe without a reader would hold the opening for ever.
    public func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        let descriptor: Int32
        do {
            descriptor = try openFile(url, O_WRONLY | O_NONBLOCK | O_NOFOLLOW, mode: 0, cancellation: cancellation)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ELOOP) {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ELOOP),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is a symbolic link and is not continued."]
            )
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENXIO) {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is a named pipe or a device and is not continued."]
            )
        }
        try requireRegularFile(descriptor, url)
        var status = stat()
        var code: Int32 = 0
        if cancellation.isCancelled {
            code = ECANCELED
        } else if probes.system("fstat", url.path, { fstat(descriptor, &status) }) != 0 {
            code = errno
        } else if let offset {
            // A file shorter than what is to be kept is not the file the caller took it for.
            if offset < 0 || offset > Int64(status.st_size) {
                code = EINVAL
            } else if offset < Int64(status.st_size),
                probes.system("ftruncate", url.path, { ftruncate(descriptor, off_t(offset)) }) != 0
            {
                code = errno
            }
        }
        guard code == 0 else {
            close(descriptor)
            if code == ECANCELED { throw CocoaError(.userCancelled) }
            throw Self.posixError(code, url)
        }
        // Writing goes on at the end of what is kept of the file. (Setting the position of a
        // regular file does not fail.)
        lseek(descriptor, off_t(offset ?? Int64(status.st_size)), SEEK_SET)
        return Writer(descriptor, url: url, defaultPermissions: nil, probes: probes)
    }

    /// `open`, where the open itself can wait (a share that does not answer): it ends, by
    /// throwing, once `cancellation` is set.
    ///
    /// Always `O_CLOEXEC`; an `EINTR` nobody asked for is tried again.
    private func openFile(_ url: URL, _ flags: Int32, mode: mode_t, cancellation: CancellationFlag) throws -> Int32 {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        let interruption = Interruption()
        let registration = cancellation.onCancel { interruption.interrupt() }
        defer {
            withExtendedLifetime(registration) {
                // Kept registered up to here.
            }
        }
        var code: Int32 = 0
        probes.willAsk?(url.path)
        let descriptor = try interruption.run { () -> Int in
            let descriptor = Darwin.open(url.path, flags | O_CLOEXEC, mode)
            if descriptor < 0 { code = errno }
            return Int(descriptor)
        }
        errno = code
        guard descriptor >= 0 else { throw Self.posixError(code, url) }
        return Int32(descriptor)
    }

    /// Anything but a regular file is refused: opening a pipe, a device or a socket can wait for
    /// ever (and reading some never ends).
    ///
    /// Called with the descriptor of a file opened without waiting. Clears `O_NONBLOCK` again for
    /// the files that pass.
    private func requireRegularFile(_ descriptor: Int32, _ url: URL) throws {
        var status = stat()
        var code: Int32 = 0
        if probes.system("fstat", url.path, { fstat(descriptor, &status) }) != 0 {
            code = errno
        } else if (status.st_mode & S_IFMT) == S_IFDIR {
            code = EISDIR
        } else if (status.st_mode & S_IFMT) != S_IFREG {
            // What `open` opens besides files and folders: a socket cannot be opened at all.
            let kind = (status.st_mode & S_IFMT) == S_IFIFO ? "a named pipe" : "a device"
            close(descriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is \(kind) and is not opened."]
            )
        } else {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0, flags & O_NONBLOCK != 0,
                probes.system("fcntl", url.path, { fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }) != 0
            {
                code = errno
            }
        }
        if code != 0 {
            close(descriptor)
            throw Self.posixError(code, url)
        }
    }
}
