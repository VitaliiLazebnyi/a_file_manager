public import AFMKernel
public import Foundation

/// A `MemoryFileSystem` behind a layer that fails the calls a test names, as a disk that fills
/// up or a server that drops the connection does. Everything else goes to the memory file
/// system as it is; only this layer is registered, under the memory file system's scheme.
///
/// Unchecked: the switches are guarded by `lock`.
public final class CoverageSmallFiles: FileSystemProvider, @unchecked Sendable {
    /// A call that can be made to fail.
    public enum Call: Sendable {
        /// Opening a file to read it.
        case open
        /// A read from an open file.
        case read
        /// Creating a file.
        case create
        /// A write to an open file.
        case write
        /// Closing a written file.
        case close
        /// Renaming.
        case move
        /// Removing.
        case remove
        /// Creating a folder.
        case createDirectory
        /// Changing the date or permissions.
        case setAttributes
        /// Listing a folder.
        case list
    }

    /// What a failing call throws.
    public struct Failure: LocalizedError {
        /// The call that failed.
        public let call: Call

        /// Says which call failed.
        public var errorDescription: String? { "The \(call) failed." }
    }

    /// A reader that fails its reads while `.read` fails.
    private final class Reader: FileReader {
        let inner: any FileReader
        let owner: CoverageSmallFiles

        init(_ inner: any FileReader, _ owner: CoverageSmallFiles) {
            (self.inner, self.owner) = (inner, owner)
        }

        func read(upToCount count: Int) throws -> Data? {
            try owner.check(.read)
            return try inner.read(upToCount: count)
        }

        func seek(to offset: UInt64) throws { try inner.seek(to: offset) }

        func close() { inner.close() }

        deinit {
            // Nothing to release.
        }
    }

    /// A writer that fails its writes and its close while `.write` and `.close` fail.
    private final class Writer: FileWriter {
        let inner: any FileWriter
        let owner: CoverageSmallFiles

        init(_ inner: any FileWriter, _ owner: CoverageSmallFiles) {
            (self.inner, self.owner) = (inner, owner)
        }

        func write(_ data: Data) throws {
            try owner.check(.write)
            try inner.write(data)
        }

        func close(attributes: FileAttributes) throws {
            try owner.check(.close)
            try inner.close(attributes: attributes)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The files.
    public let base: MemoryFileSystem
    private let lock = NSLock()
    private var failing: Set<Call> = []
    private var beforeFailing: (@Sendable (Call) -> Void)?
    private var extraCapabilities: FileSystemCapabilities = []
    private var isServer = false

    /// The scheme of the memory file system.
    public var scheme: String { base.scheme }
    /// What the memory file system can do, and `claims`.
    public var capabilities: FileSystemCapabilities { base.capabilities.union(claims) }

    /// The calls that fail from now on.
    public var fails: Set<Call> {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    /// Called on the calling thread just before a call fails, for a test that wants something
    /// to happen at that moment (a job cancelled while it writes).
    public var onFailure: (@Sendable (Call) -> Void)? {
        get { lock.withLock { beforeFailing } }
        set { lock.withLock { beforeFailing = newValue } }
    }

    /// Claimed on top of what the memory file system can do.
    public var claims: FileSystemCapabilities {
        get { lock.withLock { extraCapabilities } }
        set { lock.withLock { extraCapabilities = newValue } }
    }

    /// Whether the files are said to be on a server (`connectsToServer`); false at first.
    public var connectsToServer: Bool {
        get { lock.withLock { isServer } }
        set { lock.withLock { isServer = newValue } }
    }

    /// A layer over `base`, failing nothing yet.
    public init(_ base: MemoryFileSystem) {
        self.base = base
    }

    /// Throws when `call` fails, after `onFailure`.
    private func check(_ call: Call) throws {
        let (isFailing, hook) = lock.withLock { (failing.contains(call), beforeFailing) }
        guard isFailing else {
            return
        }
        hook?(call)
        throw Failure(call: call)
    }

    /// What the memory file system can do there, and `claims`.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        base.capabilities(for: url).union(claims)
    }

    /// The memory file system's listing, unless `.list` fails.
    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try check(.list)
        return try base.list(directory, showHidden: showHidden)
    }

    /// The memory file system's listing, unless `.list` fails.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try check(.list)
        return try base.list(directory, showHidden: showHidden, cancellation: cancellation)
    }

    /// The memory file system's item.
    public func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The memory file system's parent.
    public func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// A reader of the memory file, unless `.open` fails.
    public func read(_ url: URL) throws -> any FileReader {
        try check(.open)
        return Reader(try base.read(url), self)
    }

    /// A reader of the memory file, unless `.open` fails or the flag is set.
    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        try check(.open)
        return Reader(try base.read(url, cancellation: cancellation), self)
    }

    /// Creates the folder, unless `.createDirectory` fails.
    public func createDirectory(at url: URL) throws {
        try check(.createDirectory)
        base.createDirectory(at: url)
    }

    /// A writer of a new memory file, unless `.create` fails.
    public func write(_ url: URL) throws -> any FileWriter {
        try check(.create)
        return Writer(try base.write(url), self)
    }

    /// A writer of a new memory file, unless `.create` fails or the flag is set.
    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        try check(.create)
        return Writer(try base.write(url, cancellation: cancellation), self)
    }

    /// Removes the item, unless `.remove` fails.
    public func remove(_ url: URL) throws {
        try check(.remove)
        try base.remove(url)
    }

    /// Renames the item, unless `.move` fails.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try check(.move)
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies the file within the memory file system.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Changes the date or permissions, unless `.setAttributes` fails.
    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try check(.setAttributes)
        try base.setAttributes(attributes, of: url)
    }

    /// The memory file system's metadata copy.
    public func copyMetadata(from source: URL, to destination: URL) throws {
        try base.copyMetadata(from: source, to: destination)
    }

    /// The path as the memory file system writes it.
    public func displayPath(_ url: URL) -> String { base.displayPath(url) }

    /// The location as the memory file system reads it.
    public func location(from text: String) -> URL? { base.location(from: text) }

    /// The memory file system's places.
    public func places() -> [Place] { base.places() }

    /// The memory file system's volume.
    public func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }

    deinit {
        // Nothing to release.
    }
}
