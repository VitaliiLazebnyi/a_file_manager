import AFMKernel
import Foundation

/// Listing folders, looking at items, going up and reading members.
extension ArchiveFileSystem {
    /// The items of a folder in an archive, or of a place outside one.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try listing(directory, showHidden: showHidden, cancellation: nil)
    }

    /// The same; the flag ends the wait for the archive's opening.
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try listing(directory, showHidden: showHidden, cancellation: cancellation)
    }

    /// The items in batches: a place outside an archive is listed by its own file system, a
    /// folder in an archive is handed over in one batch.
    internal func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        if case .outside(let provider, let outer) = try resolve(directory, cancellation: nil) {
            try provider.list(outer, showHidden: showHidden, receive: receive)
            return
        }
        _ = receive(try listing(directory, showHidden: showHidden, cancellation: nil))
    }

    /// The same with the caller's flag: nothing is handed over once it is set.
    internal func list(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws {
        if case .outside(let provider, let outer) = try resolve(directory, cancellation: cancellation) {
            try provider.list(outer, showHidden: showHidden, cancellation: cancellation, receive: receive)
            return
        }
        let items = try listing(directory, showHidden: showHidden, cancellation: cancellation)
        if !cancellation.isCancelled { _ = receive(items) }
    }

    private func listing(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag?) throws -> [FileItem] {
        switch try resolve(directory, cancellation: cancellation) {
        case .outside(let provider, let outer):
            guard let cancellation else {
                return try provider.list(outer, showHidden: showHidden)
            }
            return try provider.list(outer, showHidden: showHidden, cancellation: cancellation)

        case .inside(let archive, let path, _):
            let children = try archive.children(of: path)
            let base = directory.standardized
            return children.filter { showHidden || !$0.name.hasPrefix(".") }
                .map { child in child.item(at: base.appending(name: child.name)) }
        }
    }

    /// The item at `url`; nil when there is none or the archive cannot be read.
    internal func item(at url: URL) -> FileItem? {
        item(at: url, cancellation: nil)
    }

    /// The same; nil also once the flag is set.
    internal func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        item(at: url, cancellation: Optional(cancellation))
    }

    private func item(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        guard cancellation?.isCancelled != true, let target = try? resolve(url, cancellation: cancellation) else {
            return nil
        }
        switch target {
        case .outside(let provider, let outer):
            guard let cancellation else {
                return provider.item(at: outer)
            }
            return provider.item(at: outer, cancellation: cancellation)

        case .inside(let archive, let path, _):
            if path.isEmpty {
                return FileItem(
                    url: url,
                    name: archive.name,
                    kind: .directory,
                    stat: .init(modified: archive.modified, permissions: 0o755)
                )
            }
            return archive.entry(path)?.item(at: url)
        }
    }

    /// The folder above `directory`: from an archive's top folder, the folder the archive file lies in.
    ///
    /// Works on the URL alone; nil for URLs of the other scheme.
    internal func parent(of directory: URL) -> URL? {
        // Only URLs of this scheme have a parent here; the folder that holds the archive
        // belongs to another file system, and there the climb ends.
        guard directory.scheme == scheme, let place = ArchiveURL.parse(directory) else {
            return nil
        }
        switch place {
        case .inside(let location):
            if location.isRoot {
                return location.archive.deletingLastPathComponent()
            }
            return ArchiveURL.make(
                scheme: scheme,
                archive: location.archive,
                innerPath: ArchiveTree.parent(of: location.innerPath)
            )

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.parent(of: outer)
        }
    }

    /// Where going up with `parent(of:)` ends, found at once: the folder the archive file
    /// lies in (for an archive inside archives, the folder of the outermost that this scheme
    /// shows).
    ///
    /// A location deep inside an archive is not climbed name by name for it.
    internal func root(of url: URL) -> URL {
        var current = url
        // (No honest location is nested deeper than archives may be.)
        for _ in 0..<64 {
            guard current.scheme == scheme, let place = ArchiveURL.parse(current) else { break }
            let above: URL?
            switch place {
            case .inside(let location):
                above = location.archive.deletingLastPathComponent()

            case .outside(let outer):
                above = (try? outerProvider(for: outer))?.parent(of: outer)
            }
            guard let above else { break }
            current = above
        }
        return current
    }

    /// A reader of the member at `url` (decompressing as it goes), or of a file outside the archive.
    internal func read(_ url: URL) throws -> any FileReader {
        try reading(url, cancellation: nil)
    }

    /// Opening a member that lies behind a long stretch of decompression ends when the flag is
    /// set; so does the opening of the archive.
    ///
    /// The reader that is returned is ended with its `interrupt()`.
    internal func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        try reading(url, cancellation: cancellation)
    }

    private func reading(_ url: URL, cancellation: CancellationFlag?) throws -> any FileReader {
        switch try resolve(url, cancellation: cancellation) {
        case .outside(let provider, let outer):
            guard let cancellation else {
                return try provider.read(outer)
            }
            return try provider.read(outer, cancellation: cancellation)

        case .inside(let archive, let path, _):
            guard let entry = archive.entry(path) else { throw ArchiveError.notFound(path) }
            guard !entry.isDirectory else { throw FileSystemError.notSupported("Reading the folder \(path)") }
            return try ArchiveMemberReader(cancellation: cancellation) { try archive.open(entry, slot: $0) }
        }
    }
}
