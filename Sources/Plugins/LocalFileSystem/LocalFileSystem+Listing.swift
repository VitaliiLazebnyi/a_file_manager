public import AFMKernel
public import Foundation

/// Listing folders and looking at single items.
extension LocalFileSystem {
    /// What a listing asks of every entry of a bulk read: name, kind, date, rights, flags and
    /// size, and the error of an entry that cannot be read.
    private static func listingRequest() -> attrlist {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | Entry.wantError | Entry.wantName | Entry.wantType
            | Entry.wantModified
            | Entry.wantMode | Entry.wantFlags
        request.fileattr = Entry.wantSize
        return request
    }

    /// The `count` entries a bulk read left in `buffer` that the listing shows.
    private static func entries(in buffer: UnsafeMutableRawPointer, count: Int32, showHidden: Bool) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var entry = UnsafeRawPointer(buffer)
        for _ in 0..<count {
            let (read, length) = Entry.read(at: entry)
            entry += length
            // An entry that failed is judged again when it has been asked for by itself.
            guard !read.name.isEmpty, showHidden || read.failed || !read.isHidden else { continue }
            entries.append(read)
        }
        return entries
    }

    /// Everything in the folder at once, without a flag.
    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try list(directory, showHidden: showHidden, cancellation: CancellationFlag())
    }

    /// Everything in the folder at once; a listing that was cancelled ends with what it has.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden, cancellation: cancellation) { batch in
            items += batch
            return true
        }
        return items
    }

    /// The folder in batches, without a flag; `receive` returns false to stop the listing.
    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try list(directory, showHidden: showHidden, cancellation: CancellationFlag(), receive: receive)
    }

    /// Names and attributes are fetched together, a buffer at a time, so a folder on a network
    /// share costs a few requests instead of one per file, and its entries can be shown while
    /// the rest is still coming from the server.
    ///
    /// The flag is looked at before every buffer: a listing that was cancelled ends quietly with
    /// what it has delivered.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        if try listInBulk(directory, showHidden: showHidden, cancellation: cancellation, receive: receive) {
            return
        }
        // A volume without bulk reads: every entry is examined on its own, on all cores.
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        let pieceSize = 4_000
        for start in stride(from: 0, to: names.count, by: pieceSize) {
            if cancellation.isCancelled {
                return
            }
            let piece = Array(names[start..<min(start + pieceSize, names.count)])
            let items = Parallel.map(piece, serialBelow: 512) { name in self.item(at: directory.appending(name: name)) }
                .compactMap { item in item.flatMap { $0.isHidden && !showHidden ? nil : $0 } }
            if !receive(items) {
                return
            }
        }
    }

    /// The entry as `lstat` sees it: a link has no size of its own, and what it leads to is
    /// said besides (`isDirectory`, `isSpecial`, and for a link to a file `linkTargetSize`).
    /// `device` is the volume the entry is on; for a folder another volume is mounted on,
    /// that volume's, so it differs from the device of the folder above.
    public func item(at url: URL) -> FileItem? {
        var status = stat()
        probes.willAsk?(url.path)
        guard lstat(url.path, &status) == 0 else {
            return nil
        }
        let name = url.lastPathComponent
        let type = status.st_mode & S_IFMT
        let isSymlink = type == S_IFLNK
        var isDirectory = type == S_IFDIR
        var isSpecial = type != S_IFREG && !isSymlink && !isDirectory
        var targetSize: Int64?
        if isSymlink, let target = LinkResolver.shared.resolve(url.path) {
            isDirectory = target.isDirectory
            isSpecial = target.isSpecial
            if target.isRegular { targetSize = target.size }
        }
        let isPackage = isDirectory && !isSymlink && isPackage(url)
        let modified = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return FileItem(
            url: url,
            name: name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                isPackage: isPackage,
                isHidden: name.hasPrefix(".") || (status.st_flags & UInt32(UF_HIDDEN)) != 0,
                isSpecial: isSpecial
            ),
            stat: .init(
                size: type == S_IFREG ? Int64(status.st_size) : 0,
                modified: modified,
                permissions: UInt16(status.st_mode & 0o7777)
            ),
            linkTargetSize: targetSize
        )
    }

    /// The item an entry of a bulk read of `directory` stands for; nil for one to leave out.
    internal func item(of entry: Entry, in directory: URL, showHidden: Bool) -> FileItem? {
        let url = directory.appending(name: entry.name)
        if entry.failed {
            // The bulk read knows no more than the name; the entry may still answer for itself.
            // One that does not (it was removed since) is not there: the lean listing drops it too.
            guard let item = item(at: url) else {
                return nil
            }
            return showHidden || !item.isHidden ? item : nil
        }
        let (isRegular, isSymlink) = (entry.type == VREG.rawValue, entry.type == VLNK.rawValue)
        var isDirectory = entry.type == VDIR.rawValue
        var isSpecial = !isRegular && !isSymlink && !isDirectory
        var targetSize: Int64?
        if isSymlink, let target = LinkResolver.shared.resolve(url.path) {
            // Only links cost an extra question: what do they point to?
            isDirectory = target.isDirectory
            isSpecial = target.isSpecial
            if target.isRegular { targetSize = target.size }
        }
        // A name that is not valid UTF-8 cannot be written as a location: nothing may try to open it.
        if entry.isNameRepaired { isSpecial = true }
        return FileItem(
            url: url,
            name: entry.name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                isPackage: isDirectory && !isSymlink && isPackage(url),
                isHidden: entry.isHidden,
                isSpecial: isSpecial
            ),
            stat: .init(
                size: isRegular ? entry.size : 0,
                modified: entry.modified,
                permissions: UInt16(entry.mode & 0o7777)
            ),
            linkTargetSize: targetSize
        )
    }

    /// Reads a directory with `getattrlistbulk`.
    ///
    /// Returns false when the volume does not offer it.
    private func listInBulk(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws -> Bool {
        // Opening the folder and every read of it can wait on the volume. The flag ends such
        // a wait where the system lets a signal end it; the listing then ends quietly, like
        // one that saw the flag between two buffers.
        let interruption = Interruption()
        let registration = cancellation.onCancel { interruption.interrupt() }
        defer {
            withExtendedLifetime(registration) {
                // Kept registered up to here.
            }
        }
        probes.willAsk?(directory.path)
        let path = directory.path
        guard let opened = try? interruption.run({ Int(Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)) }) else {
            return true
        }
        let descriptor = Int32(opened)
        guard descriptor >= 0 else { throw Self.posixError(errno, directory) }
        defer { close(descriptor) }
        var request = Self.listingRequest()
        let capacity = 128 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var deliveredAny = false
        // On a share every buffer is a trip to the server; none is made for a listing nobody wants.
        while !cancellation.isCancelled {
            probes.willAsk?(directory.path)
            guard
                let returned = try? interruption.run({
                    Int(
                        probes.system("getattrlistbulk", path) {
                            getattrlistbulk(descriptor, &request, buffer, capacity, 0)
                        }
                    )
                })
            else { return true }
            let count = Int32(returned)
            // The end of the directory.
            if count == 0 { break }
            if count < 0 {
                if !deliveredAny, errno == ENOTSUP || errno == EINVAL {
                    return false
                }
                throw Self.posixError(errno, directory)
            }
            deliveredAny = true
            let entries = Self.entries(in: buffer, count: count, showHidden: showHidden)
            if !receive(items(of: entries, in: directory, showHidden: showHidden)) {
                return true
            }
        }
        return true
    }

    /// Turns what was read into items.
    ///
    /// Most of the cost of an entry is making its URL, so a large batch is spread over the cores.
    /// Each piece works from its own copy of the directory's URL: threads that share one hold each
    /// other up counting its references.
    private func items(of entries: [Entry], in directory: URL, showHidden: Bool) -> [FileItem] {
        let pieceSize = 256
        guard entries.count >= pieceSize * 2, directory.baseURL == nil else {
            return entries.compactMap { item(of: $0, in: directory, showHidden: showHidden) }
        }
        let pieces = stride(from: 0, to: entries.count, by: pieceSize).map { $0..<min($0 + pieceSize, entries.count) }
        let path = directory.path
        return
            entries.withUnsafeBufferPointer { buffer in
                // Only read, and only while the call lasts.
                nonisolated(unsafe) let shared = buffer
                return Parallel.map(pieces) { piece -> [FileItem] in
                    let pieceDirectory = URL(fileURLWithPath: path, isDirectory: true)
                    return piece.compactMap { self.item(of: shared[$0], in: pieceDirectory, showHidden: showHidden) }
                }
            }
            .flatMap(\.self)
    }
}
