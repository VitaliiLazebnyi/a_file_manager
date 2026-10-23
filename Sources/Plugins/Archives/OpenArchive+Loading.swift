import Foundation

/// Reading the directory when the archive is opened.
extension OpenArchive {
    /// Reads the directory of the archive file, by its format.
    ///
    /// Called while nobody else can see the archive (opening).
    internal func load(control: StreamInterrupt?) throws {
        tree = ArchiveTree()
        unpacked = nil
        memberSource = nil
        (unlisted, hasDuplicates) = ([], false)
        (writtenCount, writtenRemovals, pendingBytes, transfers) = (changeCount, removals, 0, 0)
        let opened = file
        switch format {
        case .zip:
            let read = try Self.readZip(opened, environment: environment, control: control)
            (tree, unlisted, hasDuplicates) = (read.tree, read.unlisted, read.hasDuplicates)
            (comment, directoryOffset, prefixEnd) = (read.comment, read.directoryOffset, read.prefixEnd)

        case .tar:
            try indexTar(FileRangeStream(opened, offset: 0, length: nil), toTheEnd: false, control: control) { true }

        case .compressedTar(let codec):
            try loadStream(control: control) { interrupt in try codec.decompressing(opened, control: interrupt) }

        case .foreign:
            try loadForeign(control: control)

        case .compressedFile(let codec):
            try loadCompressedFile(codec, control: control)
        }
    }

    /// A format that the system's tools read: what they make of it is read as a TAR stream.
    private func loadForeign(control: StreamInterrupt?) throws {
        let (opened, archiveName) = (file, name)
        switch ForeignArchive.kind(of: opened) {
        case .libarchive:
            do {
                // bsdtar reads what libarchive knows and writes it out again as plain TAR:
                // one parser for every foreign format, and no tool output to interpret.
                // It is only ever given a file that `ForeignArchive` knows by its first
                // bytes: left to itself it takes a text file for a list of files to read
                // from this disk ("mtree").
                try loadStream(control: control) { interrupt in
                    guard opened.isStillAtItsPath else { throw ArchiveError.changedOutside(archiveName) }
                    return try ProcessStream(
                        Tool.bsdtar,
                        ["-cf", "-", "--format", "pax", "@" + opened.path],
                        control: interrupt
                    )
                }
            } catch ArchiveError.toolFailed(let message) where Self.meansNoArchive(message) {
                throw ArchiveError.notAnArchive(archiveName)
            }

        case .compressedTar:
            // The old `compress` format, which gzip unpacks; what comes out is read here.
            let source: (StreamInterrupt?) throws -> any ByteStream = { interrupt in
                guard opened.isStillAtItsPath else { throw ArchiveError.changedOutside(archiveName) }
                return try ProcessStream(Tool.gzip, ["-dc", "--", opened.path], control: interrupt)
            }
            let probe = try source(control)
            let first = (try? probe.readFully(TarHeader.blockSize)) ?? Data()
            probe.close()
            guard TarHeader.looksLikeHeader(first) else { throw ArchiveError.notAnArchive(archiveName) }
            try loadStream(control: control, source)

        case nil:
            throw ArchiveError.notAnArchive(archiveName)
        }
    }

    /// Watches the room in the temporary folder for a copy that is about to be made there;
    /// nil when there is not even room to begin.
    private func scratchWatch(for size: UInt64) -> SpaceWatch? {
        let folder = environment.scratch.url
        guard environment.hasRoom(environment.scratchReserve.plusClamped(size), folder) else {
            return nil
        }
        return SpaceWatch(
            folder: folder,
            reserve: environment.scratchReserve,
            step: 32 << 20,
            hasRoom: environment.hasRoom
        )
    }

    /// An archive that can only be read front to back.
    ///
    /// It is read once: the members are listed from the stream while the stream is copied into a
    /// temporary TAR, which then serves every read. A large archive, one that unpacks to more than
    /// the copy may hold, or one for whose copy the temporary folder's volume has no room to spare
    /// has no copy; its members are read from the stream.
    private func loadStream(control: StreamInterrupt?, _ source: @escaping (StreamInterrupt?) throws -> any ByteStream)
        throws
    {
        memberSource = source
        guard file.size <= environment.materializeLimit else {
            try indexTar(try source(control), toTheEnd: true, control: control) { false }
            return
        }
        let url = try environment.scratch.newFile("tar")
        guard let room = scratchWatch(for: file.size) else {
            try indexTar(try source(control), toTheEnd: true, control: control) { false }
            return
        }
        let temporary = TemporaryFile(url)
        let output = try OutputFile(creating: url, mode: 0o600)
        let copy = TeeStream(try source(control), to: output, limit: environment.unpackedLimit, room: room)
        var data: RandomAccessFile?
        try indexTar(copy, toTheEnd: true, control: control) {
            guard copy.isComplete, (try? output.close(durably: false)) != nil else {
                return false
            }
            data = try? RandomAccessFile(url, shownAs: nil)
            return data != nil
        }
        if let data { unpacked = (data, temporary) }
    }

    /// A `.gz`, `.bz2` or `.xz` file is shown as a folder holding the one file it compresses
    /// (spec 08 › Nested archives, the GZ example).
    private func loadCompressedFile(_ codec: ArchiveFormat.Codec, control: StreamInterrupt?) throws {
        var entry = try compressedEntry(codec)
        var counted: UInt64 = 0
        var counter: (any ByteStream)?
        defer { counter?.close() }
        if let data = try unpackCopy(codec, control: control, counted: &counted, counter: &counter) {
            entry.size = Int64(clamping: data.size)
            entry.content = .range(offset: 0, length: data.size)
            tree.insert(entry, keepingOrder: false)
            return
        }
        // Too large to keep a copy: every read decompresses. Only a file that does not say
        // its size (BZIP2) is read to its end for it, once, going on where the copy stopped.
        if let known = knownSize(of: codec) {
            (entry.size, entry.sizeIsExact) = (Int64(clamping: known.size), known.exact)
        } else {
            let stream = try counter ?? codec.decompressing(file, control: control)
            counter = stream
            while let block = try stream.read(upToCount: 1 << 20) {
                try control?.check()
                counted += UInt64(block.count)
            }
            entry.size = Int64(clamping: counted)
        }
        tree.insert(entry, keepingOrder: false)
    }

    /// The one entry of a compressed file, without its size: named after the file without its
    /// suffix (or by the name a GZIP header stores), dated by the file (or by the header).
    private func compressedEntry(_ codec: ArchiveFormat.Codec) throws -> ArchiveEntry {
        let suffix = "." + ArchiveFormat.suffix(codec)
        var innerName =
            name.lowercased().hasSuffix(suffix) && name.count > suffix.count
            ? String(name.dropLast(suffix.count)) : name + ".unpacked"
        var date = signature.modified
        if codec == .gzip, let header = GzipHeader(try file.read(at: 0, count: 1_024)) {
            if let stored = header.name.flatMap(ArchiveTree.normalized).map(ArchiveTree.name(of:)) {
                innerName = stored
            }
            if let time = header.modified { date = time }
        }
        innerName = ArchiveTree.normalized(innerName).map(ArchiveTree.name(of:)) ?? "unpacked"
        var entry = ArchiveEntry(
            path: innerName,
            isDirectory: false,
            packedSize: Int64(clamping: file.size),
            modified: date
        )
        entry.content = .whole
        return entry
    }

    /// What the compressed file itself says about the size of its contents, without unpacking
    /// it: exact for XZ, a claim for GZIP, nothing for BZIP2.
    private func knownSize(of codec: ArchiveFormat.Codec) -> (size: UInt64, exact: Bool)? {
        switch codec {
        case .xzStream:
            return CompressedSize.ofXZ(file).map { ($0, true) }

        case .gzip:
            return CompressedSize.claimedByGzip(file).map { ($0, false) }

        case .bzip2:
            return nil
        }
    }

    /// Decompresses a file that is small enough into a temporary copy (`unpacked`), when the
    /// temporary folder has room for it; nil when no copy was made.
    ///
    /// `counted` and `counter` are left where the copy stopped, so that the size can be counted
    /// on from there.
    private func unpackCopy(
        _ codec: ArchiveFormat.Codec,
        control: StreamInterrupt?,
        counted: inout UInt64,
        counter: inout (any ByteStream)?
    ) throws -> RandomAccessFile? {
        guard file.size <= environment.materializeLimit, case let url = try environment.scratch.newFile("bin"),
            let room = scratchWatch(for: file.size)
        else {
            return nil
        }
        let temporary = TemporaryFile(url)
        let output = try OutputFile(creating: url, mode: 0o600)
        let stream = try codec.decompressing(file, control: control)
        counter = stream
        var fits = true
        while fits, let block = try stream.read(upToCount: 1 << 20) {
            try control?.check()
            counted += UInt64(block.count)
            fits = counted <= environment.unpackedLimit && room.allows(UInt64(block.count))
            if fits { try output.write(block) }
        }
        guard fits else {
            // Given up: the room is free again at once.
            output.discard()
            try? output.close(durably: false)
            return nil
        }
        try output.close(durably: false)
        let data = try RandomAccessFile(url, shownAs: nil)
        unpacked = (data, temporary)
        return data
    }
}
