import AFMKernel
import Foundation

@testable import ArchivesPlugin

/// An archive opened the way a panel opens it: its store, the registry, its root and the file
/// system that lists it.
internal struct Opened {
    /// The store that holds the archive open.
    internal let store: ArchiveStore
    /// The local disk and the two archive file systems.
    internal let fileSystems: FileSystemRegistry
    /// The URL of the archive's top folder.
    internal let root: URL
    /// The archive file system that lists the archive.
    internal let provider: any FileSystemProvider

    /// Opens `archive` with a new store (ArchiveStore, then ArchiveFileSystem).
    @MainActor
    internal static func open(_ archive: URL) -> Self {
        let environment = ArchiveRig.environment
        let newStore = ArchiveStore(environment: environment)
        let registry = FileSystemRegistry()
        let zip = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: newStore)
        let readOnly = ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: newStore)
        let providers: [any FileSystemProvider] = [ArchiveRig.local, zip, readOnly]
        for each in providers {
            registry.register(each)
        }
        environment.fileSystems = { [weak registry] in registry }
        let scheme = ArchiveFileSystem.scheme(forArchive: archive, fileSystems: registry, isKnownZip: false)
        return Self(
            store: newStore,
            fileSystems: registry,
            root: ArchiveURL.make(scheme: scheme, archive: archive, innerPath: ""),
            provider: scheme == ArchiveURL.writableScheme ? zip : readOnly
        )
    }

    /// The URL of the member at `path` (a URL path) inside the archive.
    internal func url(path: String) -> URL {
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else {
            preconditionFailure("an archive URL without components: \(root)")
        }
        components.path = path
        guard let member = components.url else {
            preconditionFailure("no URL for \(path) in \(root)")
        }
        return member
    }
}
