import AFMContracts
import AFMKernel
import Foundation

/// A folder tree on a made-up scheme, with watchers that can be fired from any thread.
///
/// It lists nothing and writes nothing; it names any item it is asked about. Unchecked: what it
/// records is guarded by `lock`; its scheme is set once, at the start.
internal final class Review2WatchFileSystem: FileSystemProvider, @unchecked Sendable {
    /// The scheme of the file system's locations.
    internal let scheme: String
    /// The file system can do nothing beyond listing.
    internal let capabilities: FileSystemCapabilities = []
    /// Guards `watches`.
    private let lock = NSLock()
    /// The folders of each watch, and where its reports go.
    private var watches: [([URL], @Sendable ([URL]) -> Void)] = []

    /// How many folders all watches together look at.
    internal var watchedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return watches.reduce(0) { $0 + $1.0.count }
    }

    /// A file system on the scheme `r2watch`.
    internal convenience init() {
        self.init(scheme: "r2watch")
    }

    /// A file system on `scheme`.
    internal init(scheme: String) { self.scheme = scheme }

    /// The location of `path` on this file system.
    internal func url(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = path
        guard let url = components.url else {
            preconditionFailure("\(path) is not a path")
        }
        return url
    }

    /// Reports every watched folder to its watcher, on the calling thread.
    internal func fire() {
        lock.lock()
        let all = watches
        lock.unlock()
        for (directories, report) in all { report(directories) }
    }

    /// Every folder is empty.
    internal func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }

    /// An item named after the last component of `url`, whatever `url` is.
    internal func item(at url: URL) -> FileItem? { FileItem(url: url, name: url.lastPathComponent) }

    /// The folder above `directory`; none above the root.
    internal func parent(of directory: URL) -> URL? {
        directory.path == "/" ? nil : directory.deletingLastPathComponent()
    }

    /// Always throws: the file system cannot read.
    internal func read(_: URL) throws -> any FileReader { throw FileSystemError.notSupported("Reading") }

    /// Always throws: the file system cannot write.
    internal func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("Writing") }

    /// Always throws: the file system cannot write.
    internal func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }

    /// Always throws: the file system cannot write.
    internal func remove(_: URL) throws { throw FileSystemError.notSupported("Writing") }

    /// Always throws: the file system cannot write.
    internal func move(_: URL, to _: URL, replacing _: Bool) throws {
        throw FileSystemError.notSupported("Writing")
    }

    /// Always throws: the file system cannot write.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.notSupported("Writing")
    }

    /// Records the watch until the file system goes; `fire` reports to it.
    internal func watch(
        _ directories: [URL],
        onChange: @escaping @MainActor @Sendable ([URL]) -> Void
    ) -> (any WatchToken)? {
        lock.lock()
        // Fired from any thread on purpose, against the rule that reports come on the main
        // thread: the tests show that whoever watches through a virtual folder still hears on it.
        watches.append((directories, unsafeBitCast(onChange, to: (@Sendable ([URL]) -> Void).self)))
        lock.unlock()
        return self
    }

    deinit {
        // Nothing to release.
    }
}
