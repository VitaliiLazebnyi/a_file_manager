import Foundation

/// Reading the directory of a ZIP file and the headers of a TAR stream.
extension OpenArchive {
    /// Where a file of a TAR stream lies: its data's position and length, and its number.
    internal struct TarPlace {
        /// Where the file's data starts in the stream.
        internal let offset: UInt64
        /// The length of the data.
        internal let length: UInt64
        /// The file's number among the members of the stream.
        internal let index: Int
    }

    /// Reads the directory of a ZIP file.
    ///
    /// Touches nothing of an archive: whoever calls it needs no lock for it.
    internal static func readZip(_ file: RandomAccessFile, environment: ArchiveEnvironment, control: StreamInterrupt?)
        throws -> ZipListing
    {
        var listing = ZipListing()
        // The records go into the tree as they are read: no second list of them is held.
        var firstMember = UInt64.max
        var index = 0
        let contents = try ZipDirectory.scan(
            file,
            maxEntries: environment.maxEntries,
            check: { try control?.check() },
            expecting: { count in listing.tree.reserve(count) },
            { record in
                defer { index += 1 }
                if index & 0x1FFF == 0x1FFF { try control?.check() }
                if case .archive(let offset, _) = record.source { firstMember = min(firstMember, offset) }
                try add(record, to: &listing, environment: environment)
            }
        )
        listing.comment = contents.comment
        listing.directoryOffset = contents.directoryOffset
        listing.prefixEnd = min(contents.directoryOffset, firstMember)
        return listing
    }

    /// Puts a record of a ZIP's directory into the listing: by its path, or with the records
    /// that have no usable name.
    private static func add(_ record: ZipRecord, to listing: inout ZipListing, environment: ArchiveEnvironment) throws {
        var raw = record.name
        // Archives from DOS and Windows programs sometimes separate with backslashes.
        if record.versionMadeBy >> 8 != 3, !raw.contains("/") {
            raw = raw.replacingOccurrences(of: "\\", with: "/")
        }
        guard let path = ArchiveTree.normalized(raw) else {
            listing.unlisted.append(record)
            return
        }
        if let existing = listing.tree.entry(path), !existing.isImplicit { listing.hasDuplicates = true }
        listing.tree.insert(Self.entry(path: path, for: record), keepingOrder: false)
        try Self.checkSize(of: listing.tree, environment: environment)
    }

    /// Refuses a directory that would not fit the memory: too many entries, or too many folders
    /// that only the paths of their members make.
    private static func checkSize(of tree: ArchiveTree, environment: ArchiveEnvironment) throws {
        guard tree.count <= environment.maxEntries else {
            throw ArchiveError.unsupported("An archive with more than \(environment.maxEntries) entries")
        }
        guard tree.implicitBytes <= ArchiveTree.maxImplicitBytes else {
            throw ArchiveError.unsupported("An archive with this many folders inside folders")
        }
    }

    /// What bsdtar says about a file it cannot make sense of.
    internal static func meansNoArchive(_ message: String) -> Bool {
        message.isEmpty || message.contains("Unrecognized archive format") || message.contains("mtree")
    }

    /// The entry of a TAR header; a file's content is set later, when it is known how it is read.
    private static func tarEntry(_ header: TarHeader, path: String) -> ArchiveEntry {
        var entry = ArchiveEntry(
            path: path,
            isDirectory: header.kind == .directory,
            isSymbolicLink: header.kind == .symbolicLink,
            size: Int64(clamping: header.realSize ?? header.size),
            packedSize: Int64(clamping: header.size),
            modified: header.modified,
            permissions: header.permissions
        )
        if header.kind == .file, header.isSparse {
            entry.content = .unsupported(
                "Unpacking the sparse file \(path) (a file stored without its empty stretches)"
            )
        } else if header.kind == .symbolicLink {
            entry.content = .text(header.linkTarget)
            entry.size = Int64(header.linkTarget.utf8.count)
        }
        return entry
    }

    /// An archive whose directory would not fit the memory is refused while it is read.
    private func checkTreeSize() throws {
        try Self.checkSize(of: tree, environment: environment)
    }

    /// Reads the headers of a TAR stream.
    ///
    /// Of every file both its position in the stream and its number are noted; `seekable`, asked at
    /// the end, says which of the two will serve: positions when the stream is (or has become) a
    /// file, numbers otherwise. With `toTheEnd` the stream is read on behind the last member: a
    /// decompressor checks its data only then, and a child process says only then that it failed.
    internal func indexTar(
        _ stream: any ByteStream,
        toTheEnd: Bool,
        control: StreamInterrupt?,
        seekable: () -> Bool
    ) throws {
        let reader = TarReader(stream, control: control)
        defer { reader.close() }
        var located: [String: TarPlace] = [:]
        // Hard links by their own path: a later member under the same path takes the name over.
        var links: [String: String] = [:]
        var index = 0
        while let header = try reader.next() {
            defer { index += 1 }
            guard header.kind != .other, let path = ArchiveTree.normalized(header.path) else { continue }
            located[path] = nil
            links[path] = nil
            if header.kind == .file, !header.isSparse {
                located[path] = TarPlace(offset: reader.position, length: header.size, index: index)
            } else if header.kind == .hardLink, let target = ArchiveTree.normalized(header.linkTarget) {
                // Another name for a member, which may come before or after: settled below.
                links[path] = target
            }
            tree.insert(Self.tarEntry(header, path: path), keepingOrder: false)
            try checkTreeSize()
        }
        if toTheEnd {
            while try stream.read(upToCount: 1 << 16) != nil { try control?.check() }
        }
        let ranged = seekable()
        for (path, place) in located {
            tree.update(path) { entry in
                entry.content =
                    ranged ? .range(offset: place.offset, length: place.length) : .member(index: place.index)
            }
        }
        settle(links)
    }

    /// Gives every hard link (by its path, to the path it names) the content of the member it names.
    ///
    /// A link may point to a link; a few rounds settle every chain worth following.
    private func settle(_ pending: [String: String]) {
        var links = pending
        for _ in 0..<4 where !links.isEmpty {
            var left: [String: String] = [:]
            for (path, linked) in links {
                guard let target = tree.entry(linked), !target.isDirectory, links[linked] == nil else {
                    left[path] = linked
                    continue
                }
                tree.update(path) { entry in
                    (entry.content, entry.size, entry.packedSize) = (target.content, target.size, 0)
                }
            }
            if left.count == links.count { break }
            links = left
        }
    }
}
