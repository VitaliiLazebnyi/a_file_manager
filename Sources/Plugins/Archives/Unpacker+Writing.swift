import AFMKernel
import Foundation

/// Writing one member, below an open folder or by path through the target's file system.
extension Unpacker {
    /// The destination of a link member, as the file system spells a path: the bytes the archive
    /// stores, as they are.
    private static func linkDestination(_ data: Data) -> String {
        let bytes = data.map { CChar(bitPattern: $0) }
        return FileManager.default.string(withFileSystemRepresentation: bytes, length: bytes.count)
    }

    /// Writes one member.
    ///
    /// It arrives under a temporary name and gets its real name when it is complete and its
    /// checksum was right, so a damaged member never replaces a good file. Called from several
    /// threads at once, each with its own member. `quarantine` is the archive's mark, which the
    /// file gets before it appears under its name. With a `root` (a target on a disk of this
    /// machine) the member is written from that folder's descriptor down and through no link;
    /// without, by path through the target's file system.
    internal func write(_ task: Task, into root: UnpackFolder?, from stream: any ByteStream, quarantine: Data?) throws {
        if let root {
            try write(task, below: root, from: stream, quarantine: quarantine)
        } else {
            try writeByPath(task, from: stream, quarantine: quarantine)
        }
    }

    /// Writes one member below the open folder `root`.
    private func write(_ task: Task, below root: UnpackFolder, from stream: any ByteStream, quarantine: Data?) throws {
        let entry = task.entry
        if entry.isSymbolicLink {
            let destination = Self.linkDestination(try stream.readFully(1 << 16))
            try root.makeLink(task.names, to: destination, replacing: task.replaces)
            return
        }
        let (cancellation, counter, hook) = (monitor.cancellation, bytesDone, whileUnpacking)
        let file = UnpackFolder.NewFile(
            names: task.names,
            replacing: task.replaces,
            permissions: entry.permissions,
            modified: entry.modified,
            quarantine: quarantine
        )
        try root.write(file, opened: hook.map { hook in { hook(entry) } }) { put in
            while let block = try autoreleasepool(invoking: { try stream.read(upToCount: 1 << 20) }) {
                if cancellation.isCancelled { throw ArchiveError.cancelled }
                try put(block)
                counter.add(Int64(block.count))
            }
        }
    }

    /// Writes one member by path, through the file system of its target.
    private func writeByPath(_ task: Task, from stream: any ByteStream, quarantine: Data?) throws {
        let (entry, target) = (task.entry, task.target)
        let provider = try fileSystems.provider(for: target)
        if target.isFileURL, !task.replaces {
            // A link that stands where the file is to go (one that points nowhere is not
            // seen as a file that exists) is not written through.
            var status = stat()
            if lstat(target.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK {
                throw ArchiveError.unsupported("Unpacking over the symbolic link \(target.path)")
            }
        }
        if entry.isSymbolicLink {
            // A link can only be made on the local disk; elsewhere it is left out.
            guard target.isFileURL else {
                return
            }
            let destination = Self.linkDestination(try stream.readFully(1 << 16))
            if task.replaces { try provider.remove(target, cancellation: monitor.cancellation) }
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            return
        }
        let temporary = target.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
        let writer = try provider.write(temporary, cancellation: monitor.cancellation)
        // A write that waits on a server ends when the job is cancelled.
        let tie = monitor.cancellation.interrupting(writer)
        defer {
            withExtendedLifetime(tie) {
                // Only kept alive up to here.
            }
        }
        do {
            while let block = try autoreleasepool(invoking: { try stream.read(upToCount: 1 << 20) }) {
                if monitor.cancellation.isCancelled { throw ArchiveError.cancelled }
                try writer.write(block)
                bytesDone.add(Int64(block.count))
            }
            // (No more rights than the user gives new files; see `UnpackFolder.allowed`.)
            let permissions = target.isFileURL ? entry.permissions & UInt16(UnpackFolder.allowed) : entry.permissions
            try writer.close(attributes: FileAttributes(modified: entry.modified, permissions: permissions))
            Quarantine.apply(quarantine, to: temporary)
            try provider.move(temporary, to: target, replacing: task.replaces, cancellation: monitor.cancellation)
        } catch {
            try? writer.close(attributes: FileAttributes())
            try? provider.remove(temporary)
            throw error
        }
    }
}
