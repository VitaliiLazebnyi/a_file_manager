import AFMKernel
import Foundation
import TestSupport

/// A file system over memory whose files are read as if the user cancelled while the first
/// block came in: the reader sets the flag, then hands the block over.
internal final class CancellingFileSystem: FileSystemProvider, @unchecked Sendable {
    /// Sets its flag at the first read and delivers each block once.
    private final class Reader: FileReader, @unchecked Sendable {
        private let cancellation: CancellationFlag
        private var data: Data?

        init(_ data: Data, cancellation: CancellationFlag) {
            self.data = data
            self.cancellation = cancellation
        }

        func read(upToCount _: Int) -> Data? {
            cancellation.cancel()
            defer { data = nil }
            return data
        }

        func seek(to _: UInt64) {
            // Read from the start only.
        }

        func close() {
            // Nothing to close.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The memory that holds the files.
    internal let base = MemoryFileSystem(scheme: "cancelling")
    /// Its paths start at the root, as the memory's do.
    internal let readsRootedPaths = true
    private let cancellation: CancellationFlag

    /// The scheme of the memory.
    internal var scheme: String { base.scheme }
    /// What the memory can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }

    /// A file system whose readers set `cancellation` at their first read.
    internal init(cancellation: CancellationFlag) {
        self.cancellation = cancellation
    }

    /// What the memory can do at `url`.
    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }

    /// The listing of the memory.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The item of the memory at `url`.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The parent folder in the memory.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// A reader that cancels at its first read, then hands the whole file over.
    internal func read(_ url: URL) -> any FileReader {
        Reader(Data((base.contents(url.path) ?? "").utf8), cancellation: cancellation)
    }

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
