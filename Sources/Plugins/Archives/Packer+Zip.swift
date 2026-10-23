import AFMKernel
import Foundation

/// Writing a ZIP: a new one, one added to in place, or one on another file system.
extension Packer {
    /// As in an archive on a server (`OpenArchive`): a member packed again takes the place of
    /// one of its own kind only, a file that of a file and a folder that of a folder.
    ///
    /// A file under the name of a folder of the archive (one listed or one its members lie in), or
    /// a folder under the name of a file, leaves the archive as it is and fails.
    private static func refuseOtherKinds(_ members: [Member], in records: [ZipRecord], innerFolder: String) throws {
        // What each name is: what its record says, and a folder where other members lie in it.
        var folders: [String: Bool] = [:]
        for (name, isFolder) in records.compactMap({ record in
            ArchiveTree.normalized(record.name).map { ($0, record.isDirectory) }
        }) {
            folders[name] = isFolder
        }
        for name in Array(folders.keys) {
            var parent = ArchiveTree.parent(of: name)
            while !parent.isEmpty {
                folders[parent] = true
                parent = ArchiveTree.parent(of: parent)
            }
        }
        for member in members {
            let path = ArchiveTree.join(innerFolder, member.path)
            guard let isFolder = folders[path], isFolder != member.item.isRealDirectory else { continue }
            throw isFolder ? FileSystemError.alreadyExists(path) : ArchiveError.notADirectory(path)
        }
    }

    /// Adds members to an existing ZIP on the local disk without copying what it holds: the
    /// archive is cloned (which costs neither time nor space), the clone's directory is cut
    /// off, the new members and a directory that lists old and new are written behind the old
    /// members, and the clone takes the archive's place in one step.
    ///
    /// False, with nothing done, when that is not possible: a member is to be replaced, the file
    /// system does not clone, or the archive is not laid out plainly. A failed or cancelled pack
    /// leaves the archive as it was, as `build` does.
    internal func appendToZip(
        _ members: [Member],
        at archive: URL,
        innerFolder: String,
        check: () throws -> Void
    ) throws -> Bool {
        let file = try RandomAccessFile(archive, shownAs: nil)
        let contents = try ZipDirectory.read(file, maxEntries: .max, check: nil)
        try Self.refuseOtherKinds(members, in: contents.records, innerFolder: innerFolder)
        let added = Set(members.map { ArchiveTree.join(innerFolder, $0.path) })
        var offsets: [UInt64] = []
        for record in contents.records {
            guard case .archive(let offset, _) = record.source, offset < contents.directoryOffset,
                !(ArchiveTree.normalized(record.name).map(added.contains) ?? false)
            else { return false }
            offsets.append(offset)
        }
        let temporary = archive.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(UUID().uuidString).afm-pack.tmp",
                isDirectory: false
            )
        store.environment.scratch.noteExternal(temporary)
        guard store.environment.clonesArchives, clonefile(archive.path, temporary.path, 0) == 0 else {
            return false
        }
        do {
            let output = try OutputFile(extending: temporary, from: contents.directoryOffset)
            do {
                let packer = newZipPacker(output)
                for (record, offset) in zip(contents.records, offsets) { packer.writer.adopt(record, at: offset) }
                try add(members, to: packer, innerFolder: innerFolder, shownIn: archive.deletingLastPathComponent())
                try packer.finish(comment: contents.comment)
                try output.close(durably: true)
                try check()
                guard rename(temporary.path, archive.path) == 0 else { throw posixError(errno, archive.path) }
                Durable.syncFolder(of: archive)
            } catch {
                try? output.close(durably: false)
                throw error
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
        return true
    }

    /// A packer that writes to `output` as the options say.
    private func newZipPacker(_ output: OutputFile) -> ZipPacker {
        ZipPacker(
            output,
            level: options.level,
            password: options.password,
            encryption: options.encryption,
            limits: options.limits
        )
    }

    /// A new ZIP, or an existing one with the members added: what the old archive holds is
    /// copied over as it is, except the members that are packed again.
    internal func writeZip(_ members: [Member], to output: OutputFile, existing: URL?, innerFolder: String) throws {
        let packer = newZipPacker(output)
        var comment = Data()
        if let existing {
            let file = try RandomAccessFile(existing, shownAs: nil)
            let contents = try ZipDirectory.read(file, maxEntries: .max, check: nil)
            comment = contents.comment
            let replaced = Set(members.map { ArchiveTree.join(innerFolder, $0.path) })
            // What stands in front of the first member (a self-extracting program) stays.
            let first = contents.records.compactMap(\.headerOffset).reduce(contents.directoryOffset, min)
            let prefix = FileRangeStream(file, offset: 0, length: first)
            while let block = try prefix.read(upToCount: 1 << 20) { try packer.writer.append(block) }
            let kept = contents.records.filter { !(ArchiveTree.normalized($0.name).map(replaced.contains) ?? false) }
            for record in kept {
                try checkCancelled()
                try packer.writer.copyMember(record, check: nil)
            }
            // The archive stays the archive it was: its labels (the quarantine among them) go along.
            copyfile(existing.path, output.url.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
            Quarantine.apply(Quarantine.read(existing.path), to: output.url)
        }
        try add(members, to: packer, innerFolder: innerFolder, shownIn: output.url.deletingLastPathComponent())
        try packer.finish(comment: comment)
    }

    private func record(for member: Member, path: String) -> ZipRecord {
        ZipRecord.new(
            name: path,
            isDirectory: member.item.isRealDirectory,
            modified: member.item.modified,
            permissions: member.item.permissions,
            isSymbolicLink: linkTarget(of: member.item) != nil
        )
    }

    private func add(_ members: [Member], to packer: ZipPacker, innerFolder: String, shownIn place: URL) throws {
        let paths = members.map { ArchiveTree.join(innerFolder, $0.path) }
        for (member, path) in zip(members, paths) {
            lines = [
                "Packing: \(fileSystems.displayPath(member.item.url))", "To: \(fileSystems.displayPath(place))/\(path)"
            ]
            let record = record(for: member, path: path)
            if member.item.isRealDirectory {
                try packer.add(record, expectedSize: 0, stored: true) { nil }
            } else if let target = linkTarget(of: member.item) {
                var sent = false
                try packer.add(record, expectedSize: UInt64(target.utf8.count), stored: true) {
                    defer { sent = true }
                    return sent ? nil : Data(target.utf8)
                }
            } else {
                let source = try blocks(of: member.item, size: ZipPacker.pieceSize)
                defer { source.close() }
                try packer.add(record, expectedSize: UInt64(max(0, member.item.size)), stored: false, next: source.next)
            }
            done.items += 1
            report(force: false)
        }
    }

    /// Makes a change in `open`, which the store may have let go before the first change
    /// (see `OpenArchive`): then the archive is asked for again, up to eight times, after
    /// which its refusal stands.
    private func changing<T>(
        _ open: inout OpenArchive,
        at archive: URL,
        attempt: Int = 0,
        _ change: (OpenArchive) throws -> T
    ) throws -> T {
        do {
            return try change(open)
        } catch ArchiveError.retired where attempt < 8 {
            open = try store.archive(at: archive, cancellation: monitor.cancellation)
            return try changing(&open, at: archive, attempt: attempt + 1, change)
        }
    }

    /// Adds to a ZIP that is not on the local disk, through the open archive's own means.
    ///
    /// Each file is written under a temporary name and takes its real name when it is
    /// complete: a member that is packed again stays as it was until then, so a read error or
    /// Cancel leaves the archive holding what it held. With a password the members are
    /// encrypted (AES-256) as on the local disk. The writer is closed on every path.
    internal func addThroughStore(_ members: [Member], to archive: URL, innerFolder: String) throws {
        var open = try store.archive(at: archive, cancellation: monitor.cancellation)
        for member in members {
            try checkCancelled()
            let path = ArchiveTree.join(innerFolder, member.path)
            lines = [
                "Packing: \(fileSystems.displayPath(member.item.url))",
                "To: \(fileSystems.displayPath(archive))/\(path)"
            ]
            if member.item.isRealDirectory {
                try changing(&open, at: archive) { opened in try opened.makeDirectory(path) }
            } else {
                try addFile(member, at: path, to: &open, archive: archive)
            }
            done.items += 1
            report(force: false)
        }
        try open.flush(leavingOutArrivals: false, cancellation: monitor.cancellation) { _, _ in true }
    }

    /// Writes one file of `addThroughStore` under a temporary name and gives it its real `path`.
    private func addFile(_ member: Member, at path: String, to open: inout OpenArchive, archive: URL) throws {
        let temporary = ArchiveTree.join(ArchiveTree.parent(of: path), ".afm-\(UUID().uuidString).tmp")
        let writer = try changing(&open, at: archive) { opened in
            try opened.write(temporary, level: options.level, password: options.password)
        }
        do {
            let tie = monitor.cancellation.interrupting(writer)
            defer {
                withExtendedLifetime(tie) {
                    // Only kept alive up to here.
                }
            }
            let source = try blocks(of: member.item, size: 1 << 20)
            defer { source.close() }
            while let block = try source.next() { try writer.write(block) }
            try writer.close(
                attributes: FileAttributes(
                    modified: member.item.modified,
                    permissions: member.item.permissions
                )
            )
        } catch {
            // Ended, not finished: nothing of it joins the archive.
            writer.interrupt()
            try? writer.close(attributes: FileAttributes())
            try? open.remove(temporary)
            throw error
        }
        do {
            try open.move(temporary, to: path, replacing: true)
        } catch {
            try? open.remove(temporary)
            throw error
        }
    }
}
