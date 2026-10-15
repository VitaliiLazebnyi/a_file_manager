import AFMKernel
import Foundation
import TestSupport

/// A file system over memory whose listings deliver all their entries and then find the search
/// cancelled before they return, as a cancel that comes while the last part of a big folder is
/// taken in. Everything else is the memory's.
internal final class StabilityFindCancellingListing: FileSystemProvider, @unchecked Sendable {
    /// Where the files are.
    internal let base = MemoryFileSystem(scheme: "cancelling")

    /// The memory's scheme.
    internal var scheme: String { base.scheme }
    /// The memory's capabilities.
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    /// As the memory.
    internal let readsRootedPaths = true

    /// The memory's capabilities at `url`.
    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }

    /// The memory's listing.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The memory's listing, one entry at a time; then the search is cancelled.
    internal func list(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws {
        for item in try base.list(directory, showHidden: showHidden) where !receive([item]) {
            return
        }
        cancellation.cancel()
    }

    /// The memory's item.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }
    /// The memory's parent.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    /// The memory's reader.
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }
    /// The memory's writer.
    internal func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
    /// Removes from the memory.
    internal func remove(_ url: URL) throws { try base.remove(url) }

    /// Moves in the memory.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies in the memory.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Sets the attributes in the memory.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try base.setAttributes(attributes, of: url)
    }

    /// The memory's display path.
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }
    /// The memory's location of `text`.
    internal func location(from text: String) -> URL? { base.location(from: text) }
    /// The memory's volume.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
    /// Makes a folder in the memory.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    deinit {
        // Nothing to release.
    }
}
