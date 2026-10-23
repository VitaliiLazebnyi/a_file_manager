import Foundation

/// The locked copies this file system made under a temporary name, which it may still unlock to
/// rename or remove.
extension LocalFileSystem {
    /// One locked copy: which file it is, and when it was made.
    internal struct LockedCopy {
        /// The volume the file is on.
        internal let device: dev_t
        /// The file on that volume.
        internal let inode: ino_t
        /// When it was made, in nanoseconds of uptime.
        internal var made: UInt64
    }

    /// The flags that keep a file from being renamed or deleted: "Locked" in the Finder.
    internal static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    /// A temporary that was never finished is forgotten after this long.
    private static let lockedCopyLifetime: UInt64 = 6 * 3_600 * 1_000_000_000
    /// The most locked copies remembered at a time.
    private static let lockedCopyLimit = 4_096

    /// Whether `url` is named like the temporary files the callers of `copy` use for a file
    /// that is not complete yet: a dot, and `.tmp` or the `afm-` of the program's own.
    internal static func isTemporaryName(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && (name.hasSuffix(".tmp") || name.contains(".afm-"))
    }

    /// Notes the locked file at `url` (as `status` describes it) as this file system's own, if it
    /// has a temporary name.
    internal func rememberLockedCopy(_ url: URL, _ status: stat) {
        guard Self.isTemporaryName(url) else {
            return
        }
        lockedLock.lock()
        defer { lockedLock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if lockedCopies.count >= Self.lockedCopyLimit {
            // Whatever is stale goes first; only then the oldest. Never the whole table: the
            // others are temporaries of copies that are going on.
            lockedCopies = lockedCopies.filter { now &- $0.value.made < Self.lockedCopyLifetime }
            while lockedCopies.count >= Self.lockedCopyLimit,
                let oldest = lockedCopies.min(by: { $0.value.made < $1.value.made })
            {
                lockedCopies[oldest.key] = nil
            }
        }
        lockedCopies[url.path] = LockedCopy(device: status.st_dev, inode: status.st_ino, made: now)
    }

    /// The item at `url` was renamed or removed: it is no locked copy of this file system's any more.
    internal func forgetLockedCopy(_ url: URL) {
        lockedLock.lock()
        defer { lockedLock.unlock() }
        if !lockedCopies.isEmpty { lockedCopies[url.path] = nil }
    }

    /// Unlocks the file at `url` if it is a locked copy made by `copy`, and returns the flags
    /// it had, to be set again.
    ///
    /// Nil for every other file: those stay as locked as they are. The file is opened (the link
    /// itself, not its target) and checked and unlocked through that one descriptor, so the name
    /// cannot be given to another file in between.
    internal func unlockOwnCopy(_ url: URL) -> UInt32? {
        lockedLock.lock()
        let known = lockedCopies[url.path]
        lockedLock.unlock()
        guard let known else {
            return nil
        }
        if DispatchTime.now().uptimeNanoseconds &- known.made > Self.lockedCopyLifetime {
            forgetLockedCopy(url)
            return nil
        }
        var status = stat()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_SYMLINK | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            guard fstat(descriptor, &status) == 0, status.st_dev == known.device, status.st_ino == known.inode,
                status.st_flags & Self.lockFlags != 0,
                fchflags(descriptor, status.st_flags & ~Self.lockFlags) == 0
            else { return nil }
            return status.st_flags
        }
        // A file that cannot be opened for reading: by name, as before.
        guard lstat(url.path, &status) == 0, status.st_dev == known.device, status.st_ino == known.inode,
            status.st_flags & Self.lockFlags != 0,
            lchflags(url.path, status.st_flags & ~Self.lockFlags) == 0
        else { return nil }
        return status.st_flags
    }
}
