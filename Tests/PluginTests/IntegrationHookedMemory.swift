import AFMKernel
import Foundation
import TestSupport

/// A file system over memory with a moment to interfere right before a folder is made
/// exclusively.
///
/// Every call is forwarded to `base`. Unchecked: what it records is guarded by `lock`; its switches
/// are set by the test before use.
internal final class IntegrationHookedMemory: FileSystemProvider, @unchecked Sendable {
    /// The memory file system every call goes to.
    internal let base = MemoryFileSystem(scheme: "hooked")
    /// Called with the folder's URL right before a folder is made exclusively; set by the test before use.
    internal var beforeMaking: ((URL) -> Void)?
    /// The paths sent through, as `base` reads them.
    internal let readsRootedPaths = true
    /// Guards `exclusive`.
    private let lock = NSLock()
    /// The paths of the folders made exclusively, in order.
    private var exclusive: [String] = []

    /// The scheme of `base`.
    internal var scheme: String { base.scheme }
    /// What `base` can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    /// The folders that were made exclusively.
    internal var madeExclusively: [String] { lock.withLock { exclusive } }

    /// What `base` can do at `url`.
    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }

    /// The items of `directory` in `base`.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The item at `url` in `base`.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The parent of `directory` in `base`.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// A reader of the file at `url` in `base`.
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }

    /// A writer of the file at `url` in `base`.
    internal func write(_ url: URL) throws -> any FileWriter { try base.write(url) }

    /// Removes `url` from `base`.
    internal func remove(_ url: URL) throws { try base.remove(url) }

    /// Moves `source` to `destination` in `base`.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies `source` to `destination` in `base`.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Sets the attributes of `url` in `base`.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try base.setAttributes(attributes, of: url)
    }

    /// The path of `url` as `base` shows it.
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }

    /// The location `base` reads in `text`.
    internal func location(from text: String) -> URL? { base.location(from: text) }

    /// The volume of `url` in `base`.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }

    /// Makes the folder at `url` in `base`, with the folders above it.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    /// Makes the folder at `url` in `base`; an exclusive one is noted, and `beforeMaking` runs first.
    internal func createDirectory(at url: URL, exclusive: Bool) throws {
        if exclusive {
            beforeMaking?(url)
            lock.withLock { self.exclusive.append(url.path) }
        }
        try base.createDirectory(at: url, exclusive: exclusive)
    }

    /// `createDirectory(at:exclusive:)`; the flag is not looked at.
    internal func createDirectory(at url: URL, exclusive: Bool, cancellation _: CancellationFlag) throws {
        try createDirectory(at: url, exclusive: exclusive)
    }

    deinit {
        // Nothing to release.
    }
}
