import AFMKernel
import Foundation

/// Changing a ZIP: the checks, and the changes that take a moment.
extension OpenArchive {
    /// The entry of the directory that stands for a ZIP member, at `path`.
    internal static func entry(path: String, for record: ZipRecord) -> ArchiveEntry {
        ArchiveEntry(
            path: path,
            isDirectory: record.isDirectory,
            isSymbolicLink: record.isSymbolicLink,
            isSpecial: record.isSpecial,
            size: Int64(clamping: record.uncompressedSize),
            packedSize: Int64(clamping: record.compressedSize),
            modified: record.modified,
            permissions: record.permissions,
            isEncrypted: record.isEncrypted,
            content: .zip(record)
        )
    }

    /// The name a job gives a file while it brings it in (`.afm-<UUID>.tmp`).
    internal static func isTransferName(_ name: String) -> Bool {
        name.utf8.count == 45 && name.hasPrefix(".afm-") && name.hasSuffix(".tmp")
    }

    /// True for a member that came through a writer under a job's temporary name and has not
    /// been given its real name yet: it is not written into the archive file.
    internal static func isTransfer(_ entry: ArchiveEntry) -> Bool {
        guard case .zip(let record) = entry.content else {
            return false
        }
        return !record.isInArchive && record.unwritten.contains(.arriving) && isTransferName(entry.name)
    }

    /// Throws `ArchiveError.cancelled` when the flag is set.
    internal static func check(_ cancellation: CancellationFlag?) throws {
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
    }

    /// Called with the lock held, by everything that changes the archive.
    ///
    /// Answers from memory; what the disk has to say comes from `requireWritable()`, before the
    /// lock.
    internal func requireEditable() throws {
        guard !retired else { throw ArchiveError.retired }
        guard format.isEditable else { throw ArchiveError.readOnly(name) }
        guard !hasDuplicates else {
            throw ArchiveError.unsupported("Changing an archive that lists a name twice (\(name))")
        }
    }

    /// Whether the archive file can be written where it lies, and (asked once) whether its
    /// volume clones files.
    ///
    /// Called by everything that changes the archive **before** it takes the lock: the disk, and
    /// the file system an archive was fetched from, are never asked while the directory is locked.
    internal func requireWritable() throws {
        var refusal: any Error?
        if fetchedCopy != nil {
            if environment.fileSystems()?.capabilities(for: archiveURL).contains(.write) != true {
                refusal = ArchiveError.readOnly(name)
            }
        } else if access(localURL.path, W_OK) != 0 || access(localURL.deletingLastPathComponent().path, W_OK) != 0 {
            refusal = posixError(EACCES, localURL.path)
        }
        if let refusal {
            // What the archive itself has to say comes first (retired, not a ZIP).
            try locked { try requireEditable() }
            throw refusal
        }
        probeCloning()
    }

    /// Tries once whether the archive's file system makes clones.
    ///
    /// Not under the lock.
    private func probeCloning() {
        guard environment.clonesArchives,
            locked({ () -> Bool in
                defer { cloneProbed = true }
                return !cloneProbed
            })
        else { return }
        let probe = localURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(instance)-probe.afm-zip.tmp",
                isDirectory: false
            )
        unlink(probe.path)
        var result = Cloning.unknown
        if clonefile(localURL.path, probe.path, 0) == 0 {
            unlink(probe.path)
            result = .supported
        } else if errno == ENOTSUP || errno == EXDEV {
            result = .unsupported
        }
        // A write that found out meanwhile knows better.
        locked { if canClone == .unknown { canClone = result } }
    }

    /// Makes what `capabilities` answers from follow the directory.
    ///
    /// Called when it was read.
    internal func publish() {
        let editable = format.isEditable && !hasDuplicates
        stateLock.lock()
        publishedEditable = editable
        stateLock.unlock()
    }

    /// Keeps a folder that has no entry of its own from vanishing with the last thing in it.
    internal func keepFolder(_ path: String) {
        guard !path.isEmpty, let folder = tree.entry(path), folder.isImplicit, !tree.hasChildren(path) else {
            return
        }
        tree.insert(
            Self.entry(
                path: path,
                for: .new(name: path, isDirectory: true, modified: Date(), permissions: 0o755, isSymbolicLink: false)
            ),
            keepingOrder: false
        )
    }

    /// Takes an entry of the directory out of it and notes what that means for the archive file.
    internal func take(_ entry: ArchiveEntry) {
        tree.remove(entry.path)
        if case .zip(let record) = entry.content {
            if record.isInArchive {
                removals += 1
            } else {
                pendingBytes -= min(pendingBytes, record.compressedSize)
            }
        }
        if Self.isTransfer(entry) { transfers -= 1 }
    }

    /// Puts an entry into the directory that came through a writer or was taken out before.
    internal func put(_ entry: ArchiveEntry, keepingOrder: Bool) {
        tree.insert(entry, keepingOrder: keepingOrder)
        if Self.isTransfer(entry) { transfers += 1 }
    }

    /// Creates a folder and the folders above it.
    internal func makeDirectory(_ path: String) throws {
        try requireWritable()
        try locked {
            try requireEditable()
            var missing: [String] = []
            var current = path
            while !current.isEmpty {
                if let existing = tree.entry(current) {
                    guard existing.isDirectory else { throw ArchiveError.notADirectory(current) }
                    break
                }
                missing.append(current)
                current = ArchiveTree.parent(of: current)
            }
            guard !missing.isEmpty else {
                return
            }
            for folder in missing.reversed() {
                tree.insert(
                    Self.entry(
                        path: folder,
                        for: .new(
                            name: folder,
                            isDirectory: true,
                            modified: Date(),
                            permissions: 0o755,
                            isSymbolicLink: false
                        )
                    ),
                    keepingOrder: false
                )
            }
            changed()
        }
    }

    /// Removes a file or an empty folder.
    internal func remove(_ path: String) throws {
        try requireWritable()
        try locked {
            try requireEditable()
            guard let entry = tree.entry(path) else { throw ArchiveError.notFound(path) }
            if entry.isDirectory, tree.hasChildren(path) {
                throw FileSystemError.notSupported("Removing the non-empty folder \(path)")
            }
            take(entry)
            keepFolder(ArchiveTree.parent(of: path))
            changed()
        }
    }

    /// A second member with the same contents under another name.
    ///
    /// The compressed data is shared until the archive is written, and copied as it is then.
    internal func duplicate(_ source: String, to destination: String) throws -> Int64 {
        try requireWritable()
        return try locked {
            try requireEditable()
            guard var entry = tree.entry(source), !entry.isDirectory, case .zip(var record) = entry.content else {
                throw ArchiveError.notFound(source)
            }
            if tree.entry(destination) != nil { throw FileSystemError.alreadyExists(destination) }
            record.setName(destination)
            record.unwritten.remove(.arriving)
            entry.path = destination
            entry.content = .zip(record)
            tree.insert(entry, keepingOrder: false)
            if !record.isInArchive { pendingBytes = pendingBytes.plusClamped(record.compressedSize) }
            changed()
            return entry.size
        }
    }

    /// Gives a member (or a folder, which then gets an entry of its own) a new date or new permissions.
    internal func setAttributes(_ attributes: FileAttributes, of path: String) throws {
        try requireWritable()
        try locked {
            try requireEditable()
            guard var entry = tree.entry(path) else { throw ArchiveError.notFound(path) }
            var record: ZipRecord
            if case .zip(let existing) = entry.content {
                record = existing
            } else {
                record = .new(
                    name: path,
                    isDirectory: true,
                    modified: entry.modified,
                    permissions: entry.permissions,
                    isSymbolicLink: false
                )
            }
            if let date = attributes.modified { record.setModified(date) }
            if let permissions = attributes.permissions { record.setPermissions(permissions) }
            entry = Self.entry(path: path, for: record)
            tree.insert(entry, keepingOrder: false)
            changed()
        }
    }
}
