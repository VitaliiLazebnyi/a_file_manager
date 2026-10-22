import AFMKernel
import Foundation
import TestSupport

/// A file system over memory that refuses chosen moves, and that can take names differing only
/// in letter case for the same file, as a server on a Mac volume does.
///
/// Every other call goes to `base`. Unchecked: the switches are set by the test before use and
/// guarded by `lock`.
internal final class CoverageRenameFileSystem: FileSystemProvider, @unchecked Sendable {
    internal let base: MemoryFileSystem
    private let lock = NSLock()
    private var refused: Set<String> = []
    private var refusingTemporary = false
    private var folding = false

    internal var scheme: String { base.scheme }
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    internal let readsRootedPaths = true

    /// Moves to these paths fail, as on a folder without permission.
    internal var refusedTargets: Set<String> {
        get { lock.withLock { refused } }
        set { lock.withLock { refused = newValue } }
    }

    /// Whether moves to the temporary names of a rename run fail.
    internal var refusesTemporaryNames: Bool {
        get { lock.withLock { refusingTemporary } }
        set { lock.withLock { refusingTemporary = newValue } }
    }

    /// Whether an item is found under any spelling of its name.
    internal var foldsCase: Bool {
        get { lock.withLock { folding } }
        set { lock.withLock { folding = newValue } }
    }

    internal init(scheme: String = "moves") {
        base = MemoryFileSystem(scheme: scheme)
    }

    internal func url(_ path: String) -> URL { base.url(path) }

    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }

    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    internal func item(at url: URL) -> FileItem? {
        if let found = base.item(at: url) {
            return found
        }
        guard foldsCase, let listed = try? base.list(url.deletingLastPathComponent(), showHidden: true) else {
            return nil
        }
        return listed.first { $0.name.lowercased() == url.lastPathComponent.lowercased() }
    }

    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }
    internal func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
    internal func remove(_ url: URL) throws { try base.remove(url) }

    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        // Byte for byte: a name whose accents are written another way is another target.
        if refusedTargets.contains(where: { $0.utf8.elementsEqual(destination.path.utf8) })
            || (refusesTemporaryNames && destination.lastPathComponent.hasPrefix(".afm-rename-"))
        {
            throw FileSystemError.notSupported("Moving to \(destination.path)")
        }
        try base.move(source, to: destination, replacing: replacing)
    }

    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try base.setAttributes(attributes, of: url)
    }

    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }
    internal func location(from text: String) -> URL? { base.location(from: text) }
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    deinit {
        // Nothing to release.
    }
}
