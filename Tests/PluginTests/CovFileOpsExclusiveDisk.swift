import AFMKernel
import Foundation
import LocalFileSystemPlugin

/// The disk as a volume sees it that cannot rename exclusively and looks at letter case only: a move that is not to
/// replace is refused wherever the name is taken, also by the file itself under another case. With
/// `refusesReplacing`, a move that is to replace is one between volumes.
internal final class CovFileOpsExclusiveDisk: FileSystemProvider, Sendable {
    private let base = LocalFileSystem()
    private let refusesReplacing: Bool

    /// `file`.
    internal var scheme: String { base.scheme }
    /// What the disk can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }

    /// The disk; `refusesReplacing` makes every move that replaces one between volumes.
    internal init(refusesReplacing: Bool) {
        self.refusesReplacing = refusesReplacing
    }

    /// The disk's answer.
    internal func capabilities(for url: URL) -> FileSystemCapabilities {
        base.capabilities(for: url)
    }

    /// The disk's listing.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The disk's answer.
    internal func item(at url: URL) -> FileItem? {
        base.item(at: url)
    }

    /// The disk's answer.
    internal func parent(of directory: URL) -> URL? {
        base.parent(of: directory)
    }

    /// The disk's reader.
    internal func read(_ url: URL) throws -> any FileReader {
        try base.read(url)
    }

    /// The disk's writer.
    internal func write(_ url: URL) throws -> any FileWriter {
        try base.write(url)
    }

    /// Removes from the disk.
    internal func remove(_ url: URL) throws {
        try base.remove(url)
    }

    /// Refuses a move that is not to replace where the name is taken; moves on the disk otherwise.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        if !replacing, FileManager.default.fileExists(atPath: destination.path) {
            throw FileSystemError.alreadyExists(destination.path)
        }
        if replacing, refusesReplacing {
            throw FileSystemError.crossesVolumes
        }
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies on the disk.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Changes the attributes on the disk.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try base.setAttributes(attributes, of: url)
    }

    /// The disk's notation.
    internal func displayPath(_ url: URL) -> String {
        base.displayPath(url)
    }

    /// Reads the disk's notation.
    internal func location(from text: String) -> URL? {
        base.location(from: text)
    }

    /// The disk's volume.
    internal func volume(of url: URL) -> VolumeInfo? {
        base.volume(of: url)
    }

    /// Makes a folder on the disk.
    internal func createDirectory(at url: URL) throws {
        try base.createDirectory(at: url)
    }

    deinit {
        // Nothing to release.
    }
}
