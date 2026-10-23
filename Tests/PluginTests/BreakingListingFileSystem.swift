import AFMKernel
import Foundation
import TestSupport

/// A file system over memory whose listings come one entry at a time and then fail, as a server
/// that drops the connection in the middle of a large folder does.
internal final class BreakingListingFileSystem: FileSystemProvider, @unchecked Sendable {
    /// The memory that holds the files.
    internal let base = MemoryFileSystem(scheme: "breaking")
    /// Its paths start at the root, as the memory's do.
    internal let readsRootedPaths = true

    /// The scheme of the memory.
    internal var scheme: String { base.scheme }
    /// What the memory can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }

    /// What the memory can do at `url`.
    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }

    /// The whole listing at once, as the memory gives it.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The listing one entry at a time; after the last one the connection is lost.
    internal func list(
        _ directory: URL,
        showHidden: Bool,
        cancellation _: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws {
        for item in try base.list(directory, showHidden: showHidden) where !receive([item]) {
            return
        }
        throw FileSystemError.notSupported("The connection was lost")
    }

    /// The item of the memory at `url`.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The parent folder in the memory.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// Reads from the memory.
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }

    /// Writes into the memory.
    internal func write(_ url: URL) throws -> any FileWriter { try base.write(url) }

    /// Removes from the memory.
    internal func remove(_ url: URL) throws { try base.remove(url) }

    /// Moves within the memory.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies within the memory.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Sets attributes in the memory.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try base.setAttributes(attributes, of: url)
    }

    /// The path as the memory shows it.
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }

    /// The location the memory reads out of `text`.
    internal func location(from text: String) -> URL? { base.location(from: text) }

    /// The volume of the memory.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }

    /// Makes a folder in the memory.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    deinit {
        // Nothing to release.
    }
}
