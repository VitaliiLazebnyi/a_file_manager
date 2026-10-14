import AFMKernel
import Foundation
import LocalFileSystemPlugin

@testable import ArchivesPlugin

/// The program's archive file systems, set up as the plugin sets them up.
internal final class Bench: Sendable {
    /// What the archives need from their surroundings.
    internal let environment = ArchiveEnvironment()
    /// The open archives.
    internal let store: ArchiveStore
    /// The disk and both archive schemes.
    internal let fileSystems = FileSystemRegistry()
    /// The writable scheme.
    internal let zip: ArchiveFileSystem
    /// The read-only scheme.
    internal let readOnly: ArchiveFileSystem

    /// A bench whose pending changes are written `flushDelay` seconds after the last one (nil: never by itself).
    internal init(flushDelay: TimeInterval?) {
        environment.flushDelay = flushDelay
        store = ArchiveStore(environment: environment)
        zip = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store)
        readOnly = ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
        fileSystems.register(LocalFileSystem())
        fileSystems.register(zip)
        fileSystems.register(readOnly)
        environment.fileSystems = { [weak fileSystems] in fileSystems }
        environment.reportFailure = { error, name in
            Findings.shared.violation("archive reported a failed write", "\(name): \(error.localizedDescription)")
        }
        environment.contentsChanged = { _ in
            Counter.shared.add("contentsChanged callbacks")
            DispatchQueue.main.async { Counter.shared.add("contentsChanged on main") }
        }
    }

    /// The root of `archive` in the writable scheme.
    internal func inside(_ archive: URL) -> URL {
        inside(archive, "")
    }

    /// The member or folder `path` of `archive` in the writable scheme.
    internal func inside(_ archive: URL, _ path: String) -> URL {
        ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: archive, innerPath: path)
    }

    /// Reads a member to its end; nil with the error when it failed.
    internal func readAll(_ url: URL) -> (data: Data?, error: (any Error)?) {
        do {
            let reader = try zip.read(url)
            defer { reader.close() }
            var all = Data()
            while let block = try reader.read(upToCount: 1 << 20) {
                all.append(block)
            }
            return (all, nil)
        } catch {
            return (nil, error)
        }
    }

    deinit {
        // Nothing to release.
    }
}
