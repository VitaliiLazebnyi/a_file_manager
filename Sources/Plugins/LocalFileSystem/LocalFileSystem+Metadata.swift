public import AFMKernel
public import Foundation

/// Dates, rights, flags, extended attributes and the quarantine mark.
extension LocalFileSystem {
    /// The name of the extended attribute that marks what was downloaded.
    private static let quarantineName = "com.apple.quarantine"

    /// Refuses to copy metadata to or from what is not a file, a folder or a link (as `status`
    /// describes `url`): opening a pipe or a device to copy from or to it could wait for ever.
    private static func requireMetadataKind(_ status: stat, _ url: URL) throws {
        switch status.st_mode & S_IFMT {
        case S_IFREG, S_IFDIR, S_IFLNK:
            break

        default:
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(url.path) is not an ordinary file, a folder or a link: nothing is copied to or from it."
                ]
            )
        }
    }

    /// Giving the owner the right to write also unlocks an item that is locked in the Finder:
    /// the lock is the Mac's read-only attribute, and the system refuses every other change
    /// while it is set.
    ///
    /// The item itself is changed, never what a link points to; and if a change fails after the
    /// lock was taken off, the lock is put back.
    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try changeAttributes(attributes, of: url, LocalCall(probes))
    }

    /// The same; the flag ends a call that waits and keeps the next one from being begun.
    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.changeAttributes(attributes, of: url, $0) }
    }

    /// Extended attributes and access control lists are copied by the system, as it copies
    /// them with a file; the date of creation and the flags are set after them, the flags
    /// last, because a lock among them forbids everything else.
    public func copyMetadata(from source: URL, to destination: URL) throws {
        try carryMetadata(from: source, to: destination, LocalCall(probes))
    }

    /// The same; the flag ends the waiting of the first questions and of the copying of the
    /// extended attributes.
    public func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws {
        try change(at: destination, cancellation) { try self.carryMetadata(from: source, to: destination, $0) }
    }

    /// The mark of the item itself: what was downloaded says so wherever it is copied to.
    public func quarantine(of url: URL) -> Data? {
        let path = url.path
        let size = getxattr(path, Self.quarantineName, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else {
            return nil
        }
        var value = Data(count: size)
        let got = value.withUnsafeMutableBytes { buffer in
            probes.system("getxattr", path) {
                getxattr(path, Self.quarantineName, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
        }
        return got > 0 ? value.prefix(got) : nil
    }

    /// Gives the item itself (not what a link points to) the quarantine mark `value`.
    public func setQuarantine(_ value: Data, of url: URL) throws {
        try mark(value, of: url, LocalCall(probes))
    }

    /// The same; the flag ends a call that waits.
    public func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.mark(value, of: url, $0) }
    }

    /// The date an item was created: the one thing a copy between two volumes loses when
    /// only date of change and permissions travel.
    ///
    /// Set on the item itself, never on what a link points to. False when the system refuses,
    /// with `errno` set.
    @discardableResult
    internal func setCreationDate(_ date: timespec, of path: String) -> Bool {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var created = date
        return probes.system("setattrlist", path) {
            setattrlist(path, &request, &created, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        } == 0
    }

    /// Changes the date and the rights of the item itself, unlocking it first when the owner is
    /// given the right to write.
    private func changeAttributes(_ attributes: FileAttributes, of url: URL, _ call: LocalCall) throws {
        let path = url.path
        var unlocked: UInt32?
        do {
            if let permissions = attributes.permissions, permissions & 0o200 != 0 {
                var status = stat()
                if try call.run(path, { lstat(path, &status) }) == 0, status.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                    let flags = status.st_flags & ~UInt32(UF_IMMUTABLE)
                    let result = try call.run(path) { probes.system("lchflags", path) { lchflags(path, flags) } }
                    guard result == 0 else {
                        throw Self.posixError(errno, url)
                    }
                    unlocked = status.st_flags
                }
            }
            if let modified = attributes.modified {
                let seconds = modified.timeIntervalSince1970.rounded(.down)
                let nanoseconds = ((modified.timeIntervalSince1970 - seconds) * 1e9).rounded(.down)
                // The time of access stays as it is.
                var times = [
                    timespec(tv_sec: 0, tv_nsec: Int((1 << 30) - 2)),
                    timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
                ]
                if try call.run(path, { utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) }) != 0 {
                    throw Self.posixError(errno, url)
                }
            }
            if let permissions = attributes.permissions {
                // A link has no rights of its own on some volumes: that is not an error.
                if try call.run(path, { lchmod(path, mode_t(permissions) & 0o7777) }) != 0, errno != ENOTSUP,
                    errno != EOPNOTSUPP
                {
                    throw Self.posixError(errno, url)
                }
            }
        } catch {
            // Whatever stopped the change (an error, the caller's flag): a lock that was
            // taken off for it is put back.
            let code = errno
            if let unlocked { lchflags(path, unlocked) }
            errno = code
            throw error
        }
    }

    /// The flag ends the waiting of the first questions and of the copying of the extended
    /// attributes; what follows (the date of creation, the flags) is two short calls that
    /// are made in any case, so that a destination is not left with half of them.
    private func carryMetadata(from source: URL, to destination: URL, _ call: LocalCall) throws {
        guard source.isFileURL, destination.isFileURL else {
            throw FileSystemError.notSupported("Copying metadata from \(source.scheme ?? "another file system")")
        }
        var (sourceStatus, destinationStatus) = (stat(), stat())
        guard try call.run(source.path, { lstat(source.path, &sourceStatus) }) == 0 else {
            throw Self.posixError(errno, source)
        }
        guard try call.run(destination.path, { lstat(destination.path, &destinationStatus) }) == 0 else {
            throw Self.posixError(errno, destination)
        }
        try Self.requireMetadataKind(sourceStatus, source)
        try Self.requireMetadataKind(destinationStatus, destination)
        var failure: (any Error)?
        // Attributes that are there already are written again, so the call may be made twice.
        let copied = try call.run(destination.path) {
            probes.system("copyfile", destination.path) {
                copyfile(
                    source.path,
                    destination.path,
                    nil,
                    copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW)
                )
            }
        }
        if copied != 0 {
            failure = Self.posixError(errno, destination)
        }
        if sourceStatus.st_birthtimespec.tv_sec != destinationStatus.st_birthtimespec.tv_sec
            || sourceStatus.st_birthtimespec.tv_nsec != destinationStatus.st_birthtimespec.tv_nsec
        {
            if !setCreationDate(sourceStatus.st_birthtimespec, of: destination.path), failure == nil {
                failure = Self.posixError(errno, destination)
            }
        }
        carryFlags(from: sourceStatus, to: destinationStatus, at: destination, failure: &failure)
        if let failure { throw failure }
    }

    /// Gives the item at `url` (as `destination` describes it) the flags a user may set from `source`.
    ///
    /// The system's own flags stay as they are on both sides. A failure is kept in `failure` unless
    /// one is there already.
    private func carryFlags(from source: stat, to destination: stat, at url: URL, failure: inout (any Error)?) {
        let carried = UInt32(UF_HIDDEN | UF_NODUMP | UF_OPAQUE) | Self.lockFlags
        let wanted = (destination.st_flags & ~carried) | (source.st_flags & carried)
        guard wanted != destination.st_flags else {
            return
        }
        if probes.system("lchflags", url.path, { lchflags(url.path, wanted) }) != 0 {
            if failure == nil { failure = Self.posixError(errno, url) }
        } else if wanted & Self.lockFlags != 0 {
            // Locked like its source. A file still under a temporary name is still this file
            // system's to rename or remove; a folder, or a file that has its name, is the user's.
            rememberLockedCopy(url, destination)
        }
    }

    /// Sets the quarantine mark on the item itself.
    private func mark(_ value: Data, of url: URL, _ call: LocalCall) throws {
        let path = url.path
        let result = try value.withUnsafeBytes { bytes in
            try call.run(path) {
                setxattr(path, Self.quarantineName, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
        if result != 0 { throw Self.posixError(errno, url) }
    }
}
