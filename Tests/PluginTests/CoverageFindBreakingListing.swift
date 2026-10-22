import AFMKernel
import Foundation
import TestSupport

/// A file system over memory whose listings come one entry at a time and then fail, as a server
/// that drops the connection in the middle of a large folder does.
internal final class BreakingListingFileSystem: FileSystemProvider, @unchecked Sendable {
    internal let base = MemoryFileSystem(scheme: "breaking")

    internal var scheme: String { base.scheme }
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    internal let readsRootedPaths = true

    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

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

    internal func item(at url: URL) -> FileItem? { base.item(at: url) }
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }
    internal func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
    internal func remove(_ url: URL) throws { try base.remove(url) }

    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
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
    internal func createDirectory(at url: URL) throws { base.createDirectory(at: url) }

    deinit {
        // Nothing to release.
    }
}
