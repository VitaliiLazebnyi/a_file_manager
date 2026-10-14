import AFMKernel
import Foundation

/// A test file system that only lists and climbs: reading and writing are refused, and the
/// changing calls do nothing.
///
/// The conforming type says how it lists, what its parent is and where its top is.
internal protocol ListingOnly: FileSystemProvider {}

/// Everything but listing and climbing, refused or left undone.
extension ListingOnly {
    /// Nothing is known about a single entry.
    internal func item(at _: URL) -> FileItem? { nil }

    /// Reading is refused.
    internal func read(_: URL) throws -> any FileReader { throw FileSystemError.notSupported("Reading") }

    /// Writing is refused.
    internal func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }

    /// Does nothing.
    internal func createDirectory(at _: URL) {
        // Nothing is ever made.
    }

    /// Does nothing.
    internal func remove(_: URL) {
        // Nothing is ever removed.
    }

    /// Does nothing.
    internal func move(_: URL, to _: URL, replacing _: Bool) {
        // Nothing is ever moved.
    }

    /// Does nothing.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) {
        // Nothing is ever copied.
    }
}
