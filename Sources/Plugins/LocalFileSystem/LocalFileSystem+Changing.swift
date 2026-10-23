public import AFMKernel
public import Foundation

/// Making folders, removing items and moving them to the Trash.
extension LocalFileSystem {
    /// An error for a removal below a folder that found something other than a folder on its way.
    ///
    /// ELOOP and ENOTDIR are what the system says to a link or a file where a folder was.
    private static func changedOnTheWay(_ code: Int32, at name: String, to url: URL) -> any Error {
        guard code == ELOOP || code == ENOTDIR else {
            return posixError(code, url)
        }
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(name) on the way to \(url.path) is no longer a folder; nothing was removed."
            ]
        )
    }

    /// The names on the way from `root` down to `url`: the folders to go through, and the item's
    /// own name.
    ///
    /// Throws when `url` is not below `root`.
    private static func way(to url: URL, below root: URL) throws -> (folders: [String], name: String) {
        let (path, top) = (url.standardizedFileURL.path, root.standardizedFileURL.path)
        let prefix = top.hasSuffix("/") ? top : top + "/"
        guard path.utf8.count > prefix.utf8.count, path.utf8.starts(with: prefix.utf8),
            let relative = String(bytes: path.utf8.dropFirst(prefix.utf8.count), encoding: .utf8),
            case let names = PathSafety.components(ofRelativePath: relative),
            let last = names.last
        else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not below \(root.path) and is not removed."]
            )
        }
        return (Array(names.dropLast()), last)
    }

    /// Makes the folder and whatever is missing above it; an existing folder is success.
    public func createDirectory(at url: URL) throws {
        try makeDirectory(url, exclusive: false, LocalCall(probes))
    }

    /// The same; the flag ends a call that waits and keeps the next one from being begun.
    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.makeDirectory(url, exclusive: false, $0) }
    }

    /// With `exclusive`, the folder is made by one `mkdir` that fails when anything has the
    /// name, a link included (the system does not follow one there): nothing can be put in
    /// its place between a look and the making, because there is no look.
    public func createDirectory(at url: URL, exclusive: Bool) throws {
        try makeDirectory(url, exclusive: exclusive, LocalCall(probes))
    }

    /// The same with a flag that ends a call that waits.
    public func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.makeDirectory(url, exclusive: exclusive, $0) }
    }

    /// One file, one link or one empty directory; never a tree.
    public func remove(_ url: URL) throws {
        try removeItem(url, LocalCall(probes))
    }

    /// The same; the flag ends a call that waits and keeps the next one from being begun.
    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.removeItem(url, $0) }
    }

    /// The way from `root` down to the item is walked folder by folder through descriptors,
    /// each opened without following a link, and the item is removed by its name in the
    /// last of them: whatever is done to the names meanwhile, the removal happens in the
    /// folder that was reached, or not at all.
    public func remove(_ url: URL, below root: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.removeItem(url, below: root, $0) }
    }

    /// The Trash is the system's affair (`FileManager.trashItem`), which offers no way to
    /// end it early: there is no variant with a flag.
    public func trash(_ url: URL) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    /// The calls that change something, for a caller with a flag.
    ///
    /// On a disk of this Mac the change is made on the calling thread, and the flag ends a system
    /// call that waits (by a signal) and keeps the next one from being begun. On a share or an
    /// automounted folder, where a call can wait for as long as the server is away, it is made on a
    /// thread of its own so that the caller can leave it behind (`RemoteChanges`).
    internal func change<Value: Sendable>(
        at url: URL,
        _ cancellation: CancellationFlag,
        _ body: @escaping @Sendable (LocalCall) throws -> Value
    ) throws -> Value {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        let call = LocalCall(probes)
        let path = url.path
        let registration = cancellation.onCancel { call.interruption.interrupt() }
        defer {
            withExtendedLifetime(registration) {
                // Kept registered up to here.
            }
        }
        let mount = MountTable.shared.mount(containing: path)
        guard probes.isLocal?(path) ?? mount.isLocal else {
            let volume = probes.isLocal == nil ? mount.path : volumeKey(path)
            return try RemoteChanges.shared.run(
                on: volume,
                patience: probes.patienceAfterCancel,
                cancellation: cancellation,
                call,
                body
            )
        }
        return try body(call)
    }

    /// Makes the folder and whatever is missing above it.
    ///
    /// An existing folder, or a link to one, is success unless `exclusive`; anything else of that
    /// name is an error.
    private func makeDirectory(_ url: URL, exclusive: Bool, _ call: LocalCall) throws {
        let path = url.path
        func make(_ path: String) throws -> Int32 {
            try call.run(path) { mkdir(path, 0o777) } == 0 ? 0 : errno
        }
        var code = try make(path)
        if code == ENOENT {
            try makeMissingFolders(above: path, make)
            code = try make(path)
        }
        switch code {
        case 0:
            return

        case EEXIST, EISDIR:
            if exclusive { throw FileSystemError.alreadyExists(path) }
            var status = stat()
            if try call.run(path, { stat(path, &status) }) == 0, (status.st_mode & S_IFMT) == S_IFDIR {
                return
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: path, NSURLErrorKey: url])

        default:
            throw Self.posixError(code, url)
        }
    }

    /// The nearest folder above `path` that exists, then down again, each made with `make`.
    ///
    /// A folder that another thread made meanwhile is as good as one made here. (The path is
    /// absolute, and `/` always exists: the walk up ends there at the latest.)
    private func makeMissingFolders(above path: String, _ make: (String) throws -> Int32) throws {
        var missing: [String] = []
        var above = path
        while true {
            above = Self.parentPath(of: above)
            let made = try make(above)
            if made == 0 || made == EEXIST || made == EISDIR { break }
            guard made == ENOENT else {
                throw Self.posixError(made, URL(fileURLWithPath: above, isDirectory: true))
            }
            missing.append(above)
        }
        for folder in missing.reversed() {
            let made = try make(folder)
            guard made == 0 || made == EEXIST else {
                throw Self.posixError(made, URL(fileURLWithPath: folder, isDirectory: true))
            }
        }
    }

    /// Removes the item through the folders on the way from `root`, each opened without
    /// following a link (see `remove(_:below:cancellation:)`).
    private func removeItem(_ url: URL, below root: URL, _ call: LocalCall) throws {
        let (folders, last) = try Self.way(to: url, below: root)
        let (path, top) = (url.standardizedFileURL.path, root.standardizedFileURL.path)
        var folder = try call.run(top) { Darwin.open(top, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard folder >= 0 else { throw Self.changedOnTheWay(errno, at: root.lastPathComponent, to: url) }
        defer { close(folder) }
        for name in folders {
            let next = try call.run(path) { openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw Self.changedOnTheWay(errno, at: name, to: url) }
            close(folder)
            folder = next
        }
        var status = stat()
        guard try call.run(path, { fstatat(folder, last, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw Self.posixError(errno, url)
        }
        let flag = (status.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0
        if try call.run(path, { unlinkat(folder, last, flag) }) == 0 {
            forgetLockedCopy(url)
            return
        }
        var code = errno
        // A copy of a locked file that was made here is this file system's to take away again.
        if code == EPERM, let flags = unlockOwnCopy(url) {
            if unlinkat(folder, last, flag) == 0 {
                forgetLockedCopy(url)
                return
            }
            code = errno
            lchflags(url.path, flags)
        }
        throw Self.posixError(code, url)
    }

    /// Removes one file, link or empty folder by its path.
    private func removeItem(_ url: URL, _ call: LocalCall) throws {
        let path = url.path
        var status = stat()
        guard try call.run(path, { lstat(path, &status) }) == 0 else { throw Self.posixError(errno, url) }
        let isFolder = (status.st_mode & S_IFMT) == S_IFDIR
        func delete() throws -> Bool { try call.run(path) { isFolder ? rmdir(path) : unlink(path) } == 0 }
        if try delete() {
            forgetLockedCopy(url)
            return
        }
        var code = errno
        // A copy of a locked file that was made here is this file system's to take away again.
        if code == EPERM, let flags = unlockOwnCopy(url) {
            do {
                if try delete() {
                    forgetLockedCopy(url)
                    return
                }
                code = errno
            } catch {
                // Cancelled in between: the copy is as locked as it was.
                lchflags(path, flags)
                throw error
            }
            lchflags(path, flags)
        }
        throw Self.posixError(code, url)
    }
}
