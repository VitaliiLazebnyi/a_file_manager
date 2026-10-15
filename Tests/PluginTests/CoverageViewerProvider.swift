import AFMKernel
import Foundation

/// A file system whose entries and readers the test decides.
internal final class CoverageViewerProvider: FileSystemProvider {
    /// The scheme it is registered for.
    internal let scheme: String
    /// Nothing but reading.
    internal let capabilities: FileSystemCapabilities = []
    private let entry: @Sendable (URL) -> FileItem?
    private let reader: @Sendable (URL) throws -> any FileReader
    /// The mark of having come from elsewhere that every file carries; nil for none.
    private let mark: Data?

    /// A registry with this file system alone.
    internal var registry: FileSystemRegistry {
        let made = FileSystemRegistry()
        made.register(self)
        return made
    }

    /// A file system for `scheme` whose entries `entry` gives and whose files `reader` opens;
    /// every file carries `mark` as its quarantine mark.
    internal init(
        scheme: String,
        mark: Data?,
        entry: @escaping @Sendable (URL) -> FileItem?,
        reader: @escaping @Sendable (URL) throws -> any FileReader
    ) {
        self.scheme = scheme
        self.mark = mark
        self.entry = entry
        self.reader = reader
    }

    /// The same without quarantine marks.
    internal convenience init(
        scheme: String,
        entry: @escaping @Sendable (URL) -> FileItem?,
        reader: @escaping @Sendable (URL) throws -> any FileReader
    ) {
        self.init(scheme: scheme, mark: nil, entry: entry, reader: reader)
    }

    /// No listings.
    internal func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }

    /// The folder above.
    internal func parent(of directory: URL) -> URL? { directory.deletingLastPathComponent() }

    /// Not supported.
    internal func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("create") }

    /// Not supported.
    internal func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("write") }

    /// Nothing happens.
    internal func remove(_: URL) {
        // Nothing to do.
    }

    /// Nothing happens.
    internal func move(_: URL, to _: URL, replacing _: Bool) {
        // Nothing to do.
    }

    /// Nothing happens.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) {
        // Nothing to do.
    }

    /// What `entry` says.
    internal func item(at url: URL) -> FileItem? { entry(url) }

    /// What `reader` opens.
    internal func read(_ url: URL) throws -> any FileReader { try reader(url) }

    /// The mark every file carries.
    internal func quarantine(of _: URL) -> Data? { mark }

    deinit {
        // Nothing to release.
    }
}
