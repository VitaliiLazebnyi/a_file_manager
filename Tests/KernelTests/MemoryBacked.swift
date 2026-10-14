import AFMKernel
import Foundation
import TestSupport

/// A test file system that keeps its tree in a `MemoryFileSystem` and passes the calls every
/// file system must offer on to it.
///
/// What the protocol gives a default for is left to the kernel's default, unless the
/// conforming type offers it itself: that is what such a file system is there to test.
internal protocol MemoryBacked: FileSystemProvider {
    /// The file system that holds the tree.
    var inner: MemoryFileSystem { get }
}

/// The required calls, passed on to `inner`.
extension MemoryBacked {
    /// The scheme of `inner`.
    internal var scheme: String { inner.scheme }

    /// The entries of `directory` in `inner`.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try inner.list(directory, showHidden: showHidden)
    }

    /// The entry at `url` in `inner`.
    internal func item(at url: URL) -> FileItem? { inner.item(at: url) }

    /// The folder above `directory` in `inner`.
    internal func parent(of directory: URL) -> URL? { inner.parent(of: directory) }

    /// A reader of `url` in `inner`.
    internal func read(_ url: URL) throws -> any FileReader { try inner.read(url) }

    /// Makes the folder in `inner`.
    internal func createDirectory(at url: URL) { inner.createDirectory(at: url) }

    /// A writer of `url` in `inner`.
    internal func write(_ url: URL) throws -> any FileWriter { try inner.write(url) }

    /// Removes `url` from `inner`.
    internal func remove(_ url: URL) throws { try inner.remove(url) }

    /// Moves within `inner`.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }

    /// Copies within `inner`.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }
}
