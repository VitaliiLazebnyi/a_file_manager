import AFMKernel
import Foundation

/// Writing one archive: a ZIP, a TAR (compressed or not) or a single compressed file.
extension Packer {
    /// The `check` of a `build` that has nothing to look at before the new file takes its place.
    private static func noCheck() {
        // Nothing can stand in the way.
    }

    /// Packs `members` into `place`; returns the members that a test afterwards has to read:
    /// those that were added when the archive existed before, all of a new one.
    internal func pack(_ members: [Member], into place: URL, innerFolder: String) throws -> MemberChoice {
        let archive = ArchiveURL.resolved(place)
        let cancellation = monitor.cancellation
        var added = MemberChoice.all
        let existing = (try? fileSystems.provider(for: archive))?.item(at: archive, cancellation: cancellation)
        try checkCancelled()
        if options.format != .zip, existing != nil {
            if confirmReplace?(archive) == false { throw ArchiveError.cancelled }
            // What still waits to be written into the archive that is replaced is written
            // first, so that it is not written into the new one afterwards.
            try store.flush(archive, cancellation: cancellation)
        }
        newMode = Self.mode(for: members)
        switch options.format {
        case .zip:
            if existing != nil { added = .paths(members.map { ArchiveTree.join(innerFolder, $0.path) }) }
            try packZip(members, into: archive, innerFolder: innerFolder, exists: existing != nil)

        case .tar:
            try build(archive, check: Self.noCheck) { output in try writeTar(members, to: output, method: .uncompressed)
            }

        case .compressedTar(let codec):
            try build(archive, check: Self.noCheck) { output in
                try writeTar(members, to: output, method: method(for: codec))
            }

        case .compressedFile(let codec):
            try packFile(members, into: archive, codec: codec)

        case .foreign:
            throw ArchiveError.unsupported("Creating archives of this type")
        }
        if options.datesByNewest, archive.isFileURL,
            let newest = members.filter({ !$0.item.isDirectory }).map(\.item.modified).max()
        {
            try? FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: archive.path)
        }
        report(force: true)
        return added
    }

    /// Packs `members` into the ZIP at `archive`: a new one, or one that `exists` and is added to.
    private func packZip(_ members: [Member], into archive: URL, innerFolder: String, exists: Bool) throws {
        guard exists else {
            try build(archive, check: Self.noCheck) { output in
                try writeZip(members, to: output, existing: nil, innerFolder: innerFolder)
            }
            return
        }
        guard archive.isFileURL else {
            try addThroughStore(members, to: archive, innerFolder: innerFolder)
            return
        }
        // The archive file is rewritten here, not by the open archive; so that the two never
        // write at once, this holds the archive's own gate, after what waited there has been
        // written, and looks once more before the new file takes the old one's place.
        let cancellation = monitor.cancellation
        let open = try store.archive(at: archive, cancellation: cancellation)
        // Where the file really lies: a link to it stays a link.
        let real = Durable.realFile(archive)
        try open.whileHoldingFile(cancellation: cancellation) { stillUnchanged in
            if try !appendToZip(members, at: real, innerFolder: innerFolder, check: stillUnchanged) {
                try build(real, check: stillUnchanged) { output in
                    try writeZip(members, to: output, existing: real, innerFolder: innerFolder)
                }
            }
        }
    }

    /// Packs the one file of `members` into `archive`, a single compressed file.
    private func packFile(_ members: [Member], into archive: URL, codec: ArchiveFormat.Codec) throws {
        let files = members.filter { !$0.item.isDirectory }
        guard files.count == 1, let file = files.first else {
            let advice = "choose \"Create a TAR archive first\""
            throw ArchiveError.unsupported(
                "Packing several files or a folder into one \(options.format.title) file (\(advice))"
            )
        }
        try build(archive, check: Self.noCheck) { output in
            lines = [
                "Packing: \(fileSystems.displayPath(file.item.url))", "To: \(fileSystems.displayPath(archive))"
            ]
            let compressor = try ParallelCompressor(method(for: codec), to: output, modified: file.item.modified)
            let source = try blocks(of: file.item, size: 1 << 20)
            defer { source.close() }
            while let block = try source.next() { try compressor.write(block) }
            try compressor.finish()
            done.items += 1
        }
    }

    private func method(for codec: ArchiveFormat.Codec) -> ParallelCompressor.Method {
        switch codec {
        // Deflate has no "store"; the fastest level is the least it can do.
        case .gzip:
            return .gzip(level: max(1, options.level))

        case .bzip2:
            return .bzip2(level: max(1, options.level))

        case .xzStream:
            return .xzStream
        }
    }

    /// Writes the archive under a temporary name and puts it in place when it is complete, so
    /// that a failed or cancelled pack leaves no half archive and never damages an existing one.
    ///
    /// The new file is on the disk before it takes the place (see `Durable`), and it is the user's
    /// alone while it is written. An archive that is replaced keeps its rights, and one that was
    /// reached through a symbolic link is replaced where it really lies. `check` is called
    /// right before the new file takes the place and may throw to prevent that.
    private func build(_ place: URL, check: () throws -> Void, _ write: (OutputFile) throws -> Void) throws {
        guard place.isFileURL else {
            try buildElsewhere(place, write)
            return
        }
        let archive = FileManager.default.fileExists(atPath: place.path) ? Durable.realFile(place) : place
        let folder = archive.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).afm-pack.tmp", isDirectory: false)
        store.environment.scratch.noteExternal(temporary)
        var status = stat()
        let mode = stat(archive.path, &status) == 0 ? status.st_mode & 0o7777 : newMode
        let output = try OutputFile(creating: temporary, mode: 0o600)
        do {
            try write(output)
            output.setMode(mode)
            try output.close(durably: true)
            try check()
            guard rename(temporary.path, archive.path) == 0 else { throw posixError(errno, archive.path) }
            Durable.syncFolder(of: archive)
        } catch {
            try? output.close(durably: false)
            unlink(temporary.path)
            throw error
        }
    }

    /// `build` for an archive on another file system: built on the disk, then sent there.
    private func buildElsewhere(_ archive: URL, _ write: (OutputFile) throws -> Void) throws {
        let local = try store.environment.scratch.newFile("pack")
        let keeper = TemporaryFile(local)
        let output = try OutputFile(creating: local, mode: 0o600)
        try write(output)
        try output.close(durably: false)
        let provider = try fileSystems.provider(for: archive)
        try provider.createDirectory(at: archive.deletingLastPathComponent(), cancellation: monitor.cancellation)
        let temporary = archive.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
        let writer = try provider.write(temporary, cancellation: monitor.cancellation)
        // A write that waits on the server ends when the job is cancelled.
        let tie = monitor.cancellation.interrupting(writer)
        defer {
            withExtendedLifetime(tie) {
                // Only kept alive up to here.
            }
        }
        do {
            let source = FileRangeStream(try RandomAccessFile(keeper.url, shownAs: nil), offset: 0, length: nil)
            while let block = try source.read(upToCount: 1 << 20) {
                try checkCancelled()
                try writer.write(block)
            }
            try writer.close(attributes: FileAttributes())
            try provider.move(temporary, to: archive, replacing: true, cancellation: monitor.cancellation)
        } catch {
            try? writer.close(attributes: FileAttributes())
            try? provider.remove(temporary)
            throw error
        }
    }

    private func writeTar(_ members: [Member], to output: OutputFile, method: ParallelCompressor.Method) throws {
        let compressor = try ParallelCompressor(method, to: output, modified: Date())
        for member in members {
            lines = ["Packing: \(fileSystems.displayPath(member.item.url))", "To: \(member.path)"]
            var header = TarHeader(
                path: member.path,
                modified: member.item.modified,
                permissions: member.item.permissions
            )
            if member.item.isRealDirectory {
                header.kind = .directory
                try compressor.write(header.encoded())
            } else if let target = linkTarget(of: member.item) {
                header.kind = .symbolicLink
                header.linkTarget = target
                try compressor.write(header.encoded())
            } else {
                try writeTarFile(member, header: &header, to: compressor)
            }
            done.items += 1
            report(force: false)
        }
        try compressor.write(TarHeader.endOfArchive)
        try compressor.finish()
    }

    /// Writes the header and the contents of one file of a TAR.
    ///
    /// The header states the size before the data follows, so exactly that much is written even
    /// when the file changes while it is read.
    private func writeTarFile(_ member: Member, header: inout TarHeader, to compressor: ParallelCompressor) throws {
        let size = UInt64(max(0, member.item.size))
        header.size = size
        try compressor.write(header.encoded())
        let source = try blocks(of: member.item, size: 1 << 20)
        defer { source.close() }
        var written: UInt64 = 0
        while written < size, let block = try source.next() {
            let part = block.prefix(Int(min(UInt64(block.count), size - written)))
            try compressor.write(Data(part))
            written += UInt64(part.count)
        }
        // A file that shrank while it was read is filled up with zeros, a piece at a time.
        while written < size {
            let part = Int(min(size - written, 1 << 20))
            try compressor.write(Data(count: part))
            written += UInt64(part)
        }
        try compressor.write(TarHeader.padding(after: size))
    }
}
