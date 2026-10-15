import AFMKernel
import Foundation
import TestSupport

/// A memory file system (scheme `moving`) whose moves fail where the test says: for saving over a file on a file
/// system that cannot replace in one step, or cannot put a file back.
///
/// Any thread: the rule and the record are kept in `Shared` boxes.
internal final class CovCompareMovingMemory: FileSystemProvider, Sendable {
    /// Why a move failed.
    internal struct Refused: Error {}

    /// The memory file system underneath, which holds the files.
    internal let base = MemoryFileSystem(scheme: "moving")
    /// Paths from the root are this file system's own.
    internal let readsRootedPaths = true
    /// Which moves fail: from the file named first to the one named second, replacing or not. Every move works to
    /// begin with.
    internal let refuses = Shared<@Sendable (String, String, Bool) -> Bool> { _, _, _ in false }
    /// The moves asked for, as `from -> to`, by name.
    internal let moves = Shared<[String]>([])

    /// `moving`.
    internal var scheme: String { base.scheme }
    /// What the memory file system can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }

    /// Nothing is refused yet.
    internal init() {
        // The rule is set by the test.
    }

    /// The memory file system's answer.
    internal func capabilities(for url: URL) -> FileSystemCapabilities {
        base.capabilities(for: url)
    }

    /// The memory file system's listing.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The memory file system's answer.
    internal func item(at url: URL) -> FileItem? {
        base.item(at: url)
    }

    /// The memory file system's answer.
    internal func parent(of directory: URL) -> URL? {
        base.parent(of: directory)
    }

    /// The memory file system's reader.
    internal func read(_ url: URL) throws -> any FileReader {
        try base.read(url)
    }

    /// The memory file system's writer.
    internal func write(_ url: URL) throws -> any FileWriter {
        try base.write(url)
    }

    /// Removes from the memory file system.
    internal func remove(_ url: URL) throws {
        try base.remove(url)
    }

    /// Moves in the memory file system, unless the rule refuses it.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        let (from, into) = (source.lastPathComponent, destination.lastPathComponent)
        moves.modify { $0.append("\(from) -> \(into)") }
        if refuses.value(from, into, replacing) {
            throw Refused()
        }
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies in the memory file system.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Changes the attributes in the memory file system.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try base.setAttributes(attributes, of: url)
    }

    /// The memory file system's notation.
    internal func displayPath(_ url: URL) -> String {
        base.displayPath(url)
    }

    /// Reads the memory file system's notation.
    internal func location(from text: String) -> URL? {
        base.location(from: text)
    }

    /// The memory file system's volume.
    internal func volume(of url: URL) -> VolumeInfo? {
        base.volume(of: url)
    }

    /// Makes a folder in the memory file system.
    internal func createDirectory(at url: URL) {
        base.createDirectory(at: url)
    }

    deinit {
        // Nothing to release.
    }
}
