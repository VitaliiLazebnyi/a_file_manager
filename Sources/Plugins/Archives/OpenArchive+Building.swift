import AFMKernel
import Foundation

/// Building the new archive file.
extension OpenArchive {
    /// The new archive file, complete under a temporary name.
    internal struct Built {
        /// Where the new file lies (next to the archive).
        internal var url: URL
        /// Where each member's header lies in it, by the member's position in the directory.
        internal var offsets: [Int: UInt64] = [:]
        /// Where the headers of the members without a usable name lie, in their order.
        internal var unlistedOffsets: [UInt64] = []
        /// Where its directory starts.
        internal var directoryOffset: UInt64 = 0
        /// False when the old file was cloned and added to.
        internal var isRewrite = true
    }

    /// Writes a changed time into the header in front of a member's data, in the clone: the
    /// DOS time, and the exact time where the header has that field.
    ///
    /// Nothing is written before the header was found to be this member's: a directory that points
    /// elsewhere must not get another member's data overwritten.
    private static func correctTime(
        of record: ZipRecord,
        at offset: UInt64,
        in file: RandomAccessFile,
        through writer: ZipWriter
    ) throws {
        var header = ByteReader(try file.read(at: offset, count: 30))
        guard header.remaining == 30, header.u32() == ZipDirectory.localSignature else {
            throw ArchiveError.damaged("the entry \(record.name) is not where the directory says")
        }
        header.position = 26
        let (nameLength, extraLength) = (UInt64(header.u16()), Int(header.u16()))
        guard nameLength == UInt64(record.nameLength),
            try file.read(at: offset + 30, count: Int(nameLength)) == record.nameBytes
        else {
            throw ArchiveError.damaged("the entry \(record.name) is not where the directory says")
        }
        var stamp = Data()
        stamp.appendLE(record.dosTime)
        stamp.appendLE(record.dosDate)
        try writer.patch(stamp, at: offset + 10)
        // (A changed time always comes with the exact field: `ZipRecord.setModified`.)
        let exact = ZipRecord.field(0x5455, in: record.extra)
        var fields = ByteReader(try file.read(at: offset + 30 + nameLength, count: extraLength))
        while fields.remaining >= 4 {
            let (id, size) = (fields.u16(), Int(fields.u16()))
            guard size <= fields.remaining else {
                return
            }
            if id == 0x5455, size >= 5, fields.data[fields.data.startIndex + fields.position] & 1 != 0, let exact,
                exact.count >= 5
            {
                try writer.patch(
                    Data(exact.dropFirst().prefix(4)),
                    at: offset + 30 + nameLength + UInt64(fields.position) + 1
                )
                return
            }
            fields.position += size
        }
    }

    /// Puts a member into the new file; returns where its header lies there.
    ///
    /// A member that lies in the cloned file (`clone`, the old file the clone was made of) with
    /// the name it has stays where it is; every other one is copied as it is, without recompressing.
    private static func place(
        _ record: ZipRecord,
        by writer: ZipWriter,
        clone: RandomAccessFile?,
        cancellation: CancellationFlag?
    ) throws -> UInt64 {
        if let clone, case .archive(let offset, let file) = record.source, file === clone,
            !record.unwritten.contains(.name)
        {
            if record.unwritten.contains(.time) {
                try correctTime(of: record, at: offset, in: file, through: writer)
            }
            writer.adopt(record, at: offset)
            return offset
        }
        return try writer.copyMember(record, cancellation: cancellation)
    }

    /// Builds the new archive file from a snapshot, under a temporary name next to the archive.
    ///
    /// The old file is cloned and added to when that can be done (`canAppend`); otherwise the
    /// whole archive is written anew. Nothing is left behind when it fails.
    internal func build(_ snapshot: Snapshot, cancellation: CancellationFlag?, progress: (Int64, Int64) -> Bool) throws
        -> Built
    {
        var built = startBuilding(snapshot)
        do {
            let output =
                try built.isRewrite
                ? OutputFile(creating: built.url, mode: 0o600)
                : OutputFile(extending: built.url, from: snapshot.directoryOffset)
            do {
                try writeMembers(
                    of: snapshot,
                    into: &built,
                    output: output,
                    cancellation: cancellation,
                    progress: progress
                )
                try complete(output, of: built)
            } catch {
                try? output.close(durably: false)
                throw error
            }
        } catch {
            unlink(built.url.path)
            throw error
        }
        return built
    }

    /// Names the new file and, when the changes can be appended, makes it a clone of the archive.
    private func startBuilding(_ snapshot: Snapshot) -> Built {
        // One name for this archive's new file, whichever write makes it: it is noted once,
        // so that the next start can clear it away if this one dies in the middle.
        let temporary = localURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(instance).afm-zip.tmp",
                isDirectory: false
            )
        if fetchedCopy == nil,
            locked({ () -> Bool in
                defer { notedBuildFile = true }
                return !notedBuildFile
            })
        {
            environment.scratch.noteExternal(temporary)
        }
        unlink(temporary.path)
        var built = Built(url: temporary)
        if canAppend(snapshot) {
            if clonefile(localURL.path, temporary.path, 0) == 0 {
                built.isRewrite = false
            } else if errno == ENOTSUP || errno == EXDEV {
                locked { canClone = .unsupported }
            }
        }
        return built
    }

    /// Writes the members (and the directory) into the new file, noting where each one lies.
    private func writeMembers(
        of snapshot: Snapshot,
        into built: inout Built,
        output: OutputFile,
        cancellation: CancellationFlag?,
        progress: (Int64, Int64) -> Bool
    ) throws {
        let expected = Int64(clamping: snapshot.file.size.plusClamped(snapshot.pendingBytes))
        // Asked before each member: where the write stands. False ends it.
        func ask(_ written: UInt64) throws {
            if !progress(Int64(clamping: written), expected) { throw ArchiveError.cancelled }
        }
        let writer = ZipWriter(output, limits: environment.limits)
        if built.isRewrite {
            // What stands in front of the first member stays in front of it.
            let prefix = FileRangeStream(snapshot.file, offset: 0, length: snapshot.prefixEnd)
            while let block = try prefix.read(upToCount: 1 << 20) {
                try Self.check(cancellation)
                try writer.append(block)
            }
        }
        let clone = built.isRewrite ? nil : snapshot.file
        for record in snapshot.unlisted {
            try Self.check(cancellation)
            try ask(output.position)
            built.unlistedOffsets.append(try Self.place(record, by: writer, clone: clone, cancellation: cancellation))
        }
        built.offsets.reserveCapacity(snapshot.entries.count)
        for entry in snapshot.entries {
            guard case .zip(let record) = entry.content else { continue }
            try Self.check(cancellation)
            try ask(output.position)
            built.offsets[entry.order] = try Self.place(record, by: writer, clone: clone, cancellation: cancellation)
        }
        built.directoryOffset = output.position
        try writer.finish(comment: snapshot.comment)
    }

    /// Puts the new file on the disk; a file written anew takes over what the old one carried
    /// besides its contents (a clone has it already): the mode, and labels such as the quarantine.
    private func complete(_ output: OutputFile, of built: Built) throws {
        if built.isRewrite {
            var status = stat()
            if stat(localURL.path, &status) == 0 { output.setMode(status.st_mode) }
        }
        // On the disk before it takes the archive's place.
        try output.close(durably: true)
        if built.isRewrite {
            copyfile(localURL.path, built.url.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
            Quarantine.apply(Quarantine.read(localURL.path), to: built.url)
        }
    }
}
