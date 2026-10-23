import AFMKernel
import Foundation

/// Archives as folders (spec 08 › Archives as folders): a file system whose "volumes" are
/// archive files.
///
/// The same class serves two schemes, because a file system states what it can do as a whole:
/// `zip:` for archives that can be changed, `archive:` for those that are only read. See
/// `ArchiveURL` for how the URLs are made. What a particular archive can do is told by
/// `capabilities(for:)`: a ZIP that lists a name twice, or lies where nothing can be written, is
/// read-only like the others.
///
/// **Threading.** Every method may be called from any thread at once; the state is in
/// `ArchiveStore` and `OpenArchive`, which guard themselves. `parent(of:)`, `displayPath(_:)`
/// and `capabilities` work on the URL alone; `capabilities(for:)` also looks at the archives
/// that are open, never opens one, and waits for no lock that is held while a file is read or
/// written: both are safe on the main thread. So is `location(from:)`, which asks the disk
/// about a typed path that contains a name ending like an archive only where the path lies on
/// a disk of this machine, and decides from the text alone where it lies on a server.
/// Everything else may wait for a disk or a server and belongs to a background thread.
internal final class ArchiveFileSystem: FileSystemProvider {
    /// What a URL of this file system leads to (`resolve`).
    internal enum Target {
        /// A place in an open archive: the archive, the path inside it, and the location it came from.
        case inside(OpenArchive, path: String, location: ArchiveLocation)
        /// A place on the file system the archive lies on.
        case outside(any FileSystemProvider, URL)
    }

    /// The endings of files that are ZIP archives under another name.
    internal static let zipExtensions: Set<String> = [
        "zip", "jar", "war", "ear", "apk", "ipa", "epub", "cbz", "xpi", "whl", "docx", "xlsx", "pptx",
        "odt", "ods", "odp"
    ]

    /// The scheme this file system serves: `ArchiveURL.writableScheme` or `readOnlyScheme`.
    internal let scheme: String
    /// What the scheme allows as a whole: writes (kept back until a commit) for `zip:`, nothing for `archive:`.
    internal let capabilities: FileSystemCapabilities
    /// The open archives, shared by both schemes.
    internal let store: ArchiveStore

    /// What lies at a path of this machine, without asking a volume that may not answer
    /// (`Volume.kind(ofLocalPath:)`).
    internal let pathKind: @Sendable (String) -> Volume.PathKind

    /// The registry the archives' own file systems are found in; nil once the program is gone.
    internal var fileSystems: FileSystemRegistry? { store.environment.fileSystems() }

    /// The file system of `scheme`, with the archives of `store`, that asks the disks what a typed path is.
    internal convenience init(scheme: String, store: ArchiveStore) {
        self.init(scheme: scheme, store: store) { Volume.kind(ofLocalPath: $0) }
    }

    /// The same with `pathKind` in place of the look at the disks (tests: a path on a server).
    internal init(scheme: String, store: ArchiveStore, pathKind: @escaping @Sendable (String) -> Volume.PathKind) {
        self.scheme = scheme
        self.store = store
        self.pathKind = pathKind
        capabilities = scheme == ArchiveURL.writableScheme ? [.write, .deferredWrites] : []
    }

    /// Which of the two schemes an archive file is shown under: the writable one for ZIP
    /// files on a file system that can itself be written to.
    ///
    /// A file is a ZIP when `isKnownZip` says so (its contents were looked at) or its name ends like one.
    internal static func scheme(forArchive url: URL, fileSystems: FileSystemRegistry?, isKnownZip: Bool) -> String {
        let zip = isKnownZip || zipExtensions.contains(url.pathExtension.lowercased())
        let writable = fileSystems?.capabilities(for: url).contains(.write) ?? false
        return zip && writable ? ArchiveURL.writableScheme : ArchiveURL.readOnlyScheme
    }

    /// Throws `ArchiveError.cancelled` once the flag is set.
    internal static func check(_ cancellation: CancellationFlag?) throws {
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
    }

    /// The file system that `url` (a place outside any archive) belongs to.
    internal func outerProvider(for url: URL) throws -> any FileSystemProvider {
        guard let fileSystems else { throw FileSystemError.noProvider(url) }
        return try fileSystems.provider(for: url)
    }

    /// What `url` leads to, opening its archive when needed (a `cancellation` ends the wait).
    ///
    /// A folder named like an archive leads outside: the place is further down that folder.
    /// Throws when the archive cannot be opened or `url` is no URL of the archive schemes.
    internal func resolve(_ url: URL, cancellation: CancellationFlag?) throws -> Target {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            do {
                return .inside(
                    try store.archive(at: location.archive, cancellation: cancellation),
                    path: location.innerPath,
                    location: location
                )
            } catch ArchiveError.notAnArchive {
                return try folderNamedLikeAnArchive(location, cancellation: cancellation)
            }

        case .outside(let outer):
            return .outside(try outerProvider(for: outer), outer)

        case nil:
            throw FileSystemError.noProvider(url)
        }
    }

    /// The place `location` names when its "archive" is no archive: a folder that is named like
    /// an archive (a typed path on a server is read by its text alone), the place simply further
    /// down that folder.
    private func folderNamedLikeAnArchive(_ location: ArchiveLocation, cancellation: CancellationFlag?) throws
        -> Target
    {
        let provider = try outerProvider(for: location.archive)
        let found =
            cancellation.map { provider.item(at: location.archive, cancellation: $0) }
            ?? provider.item(at: location.archive)
        guard found?.isRealDirectory == true else {
            throw ArchiveError.notAnArchive(location.archive.lastPathComponent)
        }
        let place = ArchiveTree.names(of: location.innerPath)
            .reduce(location.archive) { folder, name in folder.appending(name: name) }
        return .outside(provider, place)
    }

    deinit {
        // Nothing to release.
    }
}
