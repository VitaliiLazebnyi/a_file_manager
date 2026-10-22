public import AFMKernel
public import Foundation

/// A memory file system (scheme `race`) on which another program makes a folder in the same
/// moment as the caller: a look at `hidesOnce` with a cancellation flag finds nothing, once,
/// though the folder is there, so that making it exclusively then finds it made.
///
/// Unchecked: `hidden` is guarded by `lock`; the rest is the inner file system, which is safe
/// from any thread.
public final class CoverageArchivesFormatsRacingFileSystem: FileSystemProvider, @unchecked Sendable {
    /// Where everything really is.
    public let inner = MemoryFileSystem(scheme: "race")
    private let lock = NSLock()
    private var hidden: String?

    /// The scheme of the inner file system.
    public var scheme: String { inner.scheme }

    /// What the inner file system can do.
    public var capabilities: FileSystemCapabilities { inner.capabilities }

    /// The path (as `MemoryFileSystem.url(_:)` takes it) that the next look with a flag misses.
    public var hidesOnce: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hidden
        }
        set {
            lock.lock()
            hidden = newValue
            lock.unlock()
        }
    }

    /// A file system with nothing in it and nothing hidden.
    public init() {
        // Nothing else to set up.
    }

    /// The listing of the inner file system.
    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try inner.list(directory, showHidden: showHidden)
    }

    /// What is at `url`, without missing anything.
    public func item(at url: URL) -> FileItem? {
        inner.item(at: url)
    }

    /// What is at `url`; nothing, once, at the hidden path.
    public func item(at url: URL, cancellation _: CancellationFlag) -> FileItem? {
        lock.lock()
        let hides = hidden.map { inner.url($0) == url } ?? false
        if hides {
            hidden = nil
        }
        lock.unlock()
        return hides ? nil : inner.item(at: url)
    }

    /// The folder above, as the inner file system has it.
    public func parent(of directory: URL) -> URL? {
        inner.parent(of: directory)
    }

    /// Reads from the inner file system.
    public func read(_ url: URL) throws -> any FileReader {
        try inner.read(url)
    }

    /// Makes a folder in the inner file system.
    public func createDirectory(at url: URL) {
        inner.createDirectory(at: url)
    }

    /// Writes into the inner file system.
    public func write(_ url: URL) throws -> any FileWriter {
        try inner.write(url)
    }

    /// Removes from the inner file system.
    public func remove(_ url: URL) throws {
        try inner.remove(url)
    }

    /// Moves within the inner file system.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }

    /// Copies within the inner file system.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }

    /// Sets attributes in the inner file system.
    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try inner.setAttributes(attributes, of: url)
    }

    deinit {
        // Nothing to release.
    }
}
