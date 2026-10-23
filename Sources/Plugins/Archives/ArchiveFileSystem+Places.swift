import AFMKernel
import Foundation

/// What a single location can do, writing kept-back changes, the quarantine mark, the order of
/// reads, and how locations are shown and typed.
extension ArchiveFileSystem {
    /// A typed path with a leading `~` made absolute; nil for a path that is not absolute.
    private static func absolutePath(_ text: String) -> String? {
        let path = text == "~" || text.hasPrefix("~/") ? NSHomeDirectory() + text.dropFirst() : text
        return path.hasPrefix("/") ? path : nil
    }

    /// What can be done at `url`: what the archive allows if it is open (the scheme's word
    /// until then), or what the file system outside allows.
    ///
    /// Never opens an archive: safe on the main thread.
    internal func capabilities(for url: URL) -> FileSystemCapabilities {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            guard !capabilities.isEmpty else {
                return []
            }
            // What is known of the archive if it is open; the scheme's word until then.
            return store.openArchive(at: location.archive)?.capabilities ?? capabilities

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.capabilities(for: outer) ?? []

        case nil:
            return []
        }
    }

    /// Writes into the archive file whatever is still kept back for it: the new members, the
    /// renames, removals and changes of attributes.
    ///
    /// For an archive that lies in another archive or on a server that keeps writes back, that one
    /// is committed too, so that it is the last to hold the data. Returns when the file on the disk
    /// holds it all; throws what the write throws, and the changes wait for the next attempt.
    internal func commit(_ url: URL, cancellation: CancellationFlag) throws {
        try committing(url, cancellation: cancellation) { _, _ in true }
    }

    /// The same, asking `progress` between the members that are written (and, for an archive
    /// that came from a server, between the blocks that are sent back): with the bytes
    /// written and expected, and false ends the write, which then has changed nothing.
    ///
    /// A job that is paused waits inside `progress`, so Pause takes hold in a commit that is under
    /// way (F046).
    internal func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        var stopped = false
        do {
            try committing(url, cancellation: cancellation) { done, total in
                if !progress(done, total) { stopped = true }
                return !stopped
            }
        } catch ArchiveError.cancelled where stopped {
            // What the protocol says of a commit that `progress` ended.
            throw CocoaError(.userCancelled)
        }
    }

    private func committing(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            try store.commit(location.archive, cancellation: cancellation, progress: progress)
            if let outer = try? outerProvider(for: location.archive),
                outer.capabilities(for: location.archive).contains(.deferredWrites)
            {
                try outer.commit(location.archive, cancellation: cancellation, progress: progress)
            }

        case .outside(let outer):
            try outerProvider(for: outer).commit(outer, cancellation: cancellation, progress: progress)

        case nil:
            break
        }
    }

    /// The mark of the archive file itself, which everything inside carries (for an archive
    /// inside another archive, the outermost file's).
    internal func quarantine(of url: URL) -> Data? {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            // Of the archive that is open, without waiting; it is opened only when it is not.
            return
                (store.openArchive(at: location.archive)
                ?? (try? store.archive(at: location.archive, cancellation: nil)))?
                .quarantine

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.quarantine(of: outer)

        case nil:
            return nil
        }
    }

    /// Members of an archive cannot carry a mark; a place outside it may.
    internal func setQuarantine(_ value: Data, of url: URL) throws {
        if case .outside(let outer)? = ArchiveURL.parse(url) {
            try outerProvider(for: outer).setQuarantine(value, of: outer)
        }
    }

    /// The same with the caller's flag, handed on to the file system outside.
    internal func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        if case .outside(let outer)? = ArchiveURL.parse(url) {
            try outerProvider(for: outer).setQuarantine(value, of: outer, cancellation: cancellation)
        }
    }

    /// A place that only passes through an archive scheme is the place on the file system
    /// the archive lies on; a place inside an archive is itself.
    ///
    /// Works on the URL alone.
    internal func realLocation(of url: URL) -> URL? {
        if case .outside(let outer)? = ArchiveURL.parse(url) {
            return outer
        }
        return nil
    }

    /// The members of an archive that can only be read front to back (a compressed TAR, a 7z
    /// too large for a temporary copy) come in the order they lie in it: read that way, one
    /// pass through the archive serves them all (a reader that has delivered a member waits
    /// for the next, see `OpenArchive.open`), where any other order starts the decompression
    /// over for every member that lies before the one read last.
    ///
    /// Members of archives that are read at any place, and locations that are no members, keep
    /// their places.
    ///
    /// Opens no archive: one that is not open yet is opened by the first read, and its
    /// members are then read in the order given. Not for the main thread all the same (it
    /// takes the archive's lock for the look-ups).
    internal func readOrder(of urls: [URL]) -> [URL] {
        guard urls.count > 1 else {
            return urls
        }
        var archives: [String: OpenArchive?] = [:]
        var places: [String: [(index: Int, order: Int)]] = [:]
        for (index, url) in urls.enumerated() {
            guard case .inside(let location)? = ArchiveURL.parse(url), !location.isRoot else { continue }
            let key = location.archive.locationKey
            if archives[key] == nil {
                let open = store.openArchive(at: location.archive)
                archives[key] = .some(open?.allowsParallelReads == false ? open : nil)
            }
            guard let archive = archives[key].flatMap(\.self), let entry = archive.entry(location.innerPath) else {
                continue
            }
            places[key, default: []].append((index, entry.order))
        }
        guard !places.isEmpty else {
            return urls
        }
        var result = urls
        for members in places.values where members.count > 1 {
            // The members of one archive change places among themselves only.
            let sorted = members.sorted { ($0.order, $0.index) < ($1.order, $1.index) }
            for (slot, member) in zip(members.map(\.index), sorted) { result[slot] = urls[member.index] }
        }
        return result
    }

    /// The path of the archive file with the path inside appended, as Total Commander shows
    /// it: `/Users/me/photos.zip/2026`.
    internal func displayPath(_ url: URL) -> String {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            let archive = fileSystems?.displayPath(location.archive) ?? location.archive.path
            return location.isRoot ? archive : archive + "/" + location.innerPath

        case .outside(let outer):
            return fileSystems?.displayPath(outer) ?? outer.path

        case nil:
            return url.absoluteString
        }
    }

    /// Reads the full URL form and what `displayPath` writes for archives on the local disk:
    /// a path that runs through a file whose name ends like an archive.
    ///
    /// This is called on the main thread for every path the user types, so it never asks a
    /// volume that may not answer. Where the path lies on a disk of this machine the disk
    /// says whether the name is a file (an archive), a folder or nothing, as fast as it says
    /// anything. Where it lies on a server the text decides: a path that goes on behind such
    /// a name runs through an archive (and if the name turns out to be a folder, the listing
    /// finds that out in the background and shows the folder); a path that ends with the name
    /// is the file itself, as it is for a new archive that Pack is to write.
    internal func location(from text: String) -> URL? {
        if text.lowercased().hasPrefix(scheme + "://"), let url = URL(string: text), url.scheme == scheme {
            return url
        }
        guard let path = Self.absolutePath(text) else {
            return nil
        }
        let names = ArchiveTree.names(of: path)
        let known = store.environment.options.extensions.union(Self.zipExtensions)
            .union(ArchiveFormat.writable.flatMap(\.extensions))
        var prefix = ""
        for (index, name) in names.enumerated() {
            prefix += "/" + name
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard !ext.isEmpty, known.contains(ext) else { continue }
            switch pathKind(prefix) {
            case .regularFile:
                break

            case .directory, .other:
                continue

            case .missing:
                return nil

            case .unasked:
                if index == names.count - 1 {
                    return nil
                }
            }
            let archive = URL(fileURLWithPath: prefix, isDirectory: false)
            guard Self.scheme(forArchive: archive, fileSystems: fileSystems, isKnownZip: false) == scheme else {
                return nil
            }
            let inner = ArchiveTree.normalized(names[(index + 1)...].joined(separator: "/")) ?? ""
            return ArchiveURL.make(scheme: scheme, archive: archive, innerPath: inner)
        }
        return nil
    }

    /// The volume of a location: the archive file for a place inside it, the outer file
    /// system's volume for a place outside.
    internal func volume(of url: URL) -> VolumeInfo? {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            return VolumeInfo(name: location.archive.lastPathComponent)

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.volume(of: outer)

        case nil:
            return nil
        }
    }

    /// The same with the caller's flag, handed on to the file system outside.
    internal func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            return VolumeInfo(name: location.archive.lastPathComponent)

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.volume(of: outer, cancellation: cancellation)

        case nil:
            return nil
        }
    }
}
