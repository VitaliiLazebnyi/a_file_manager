import Foundation

@testable import AFMKernel

/// A file system whose listings break off after their first batch.
///
/// As a disk that fails or a server that goes away halfway through a large folder. Everything
/// else is not supported.
internal final class PanelsBrokenListing: FileSystemProvider, Sendable {
    /// Why the listing broke off.
    internal struct Broken: Error {}

    /// The scheme of its URLs.
    internal let scheme = "broken"
    /// It cannot be written.
    internal let capabilities = FileSystemCapabilities()

    /// A URL of this file system.
    internal func url(_ path: String) -> URL {
        URL(string: "broken://host" + path) ?? URL(fileURLWithPath: path)
    }

    /// The first batch, then the error.
    internal func list(
        _ directory: URL,
        showHidden _: Bool,
        cancellation _: CancellationFlag,
        receive: ([FileItem]) -> Bool
    )
        throws
    {
        let item = FileItem(url: directory.appendingPathComponent("first"), name: "first", isDirectory: false)
        _ = receive([item])
        throw Broken()
    }

    /// Every listing breaks off.
    internal func list(_: URL, showHidden _: Bool) throws -> [FileItem] { throw Broken() }

    /// Every location is a folder.
    internal func item(at url: URL) -> FileItem? {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: true)
    }

    /// The folder above, up to the host.
    internal func parent(of directory: URL) -> URL? {
        directory.path == "/" || directory.path.isEmpty ? nil : directory.deletingLastPathComponent()
    }

    /// Not supported.
    internal func read(_: URL) throws -> any FileReader { throw Broken() }

    /// Not supported.
    internal func createDirectory(at _: URL) throws { throw Broken() }

    /// Not supported.
    internal func write(_: URL) throws -> any FileWriter { throw Broken() }

    /// Not supported.
    internal func remove(_: URL) throws { throw Broken() }

    /// Not supported.
    internal func move(_: URL, to _: URL, replacing _: Bool) throws { throw Broken() }

    /// Not supported.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws { throw Broken() }

    deinit {
        // Nothing to release.
    }
}
