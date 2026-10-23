public import AFMKernel
public import Foundation

/// A `MemoryFileSystem` behind a layer that fails the calls a test names, as a disk that fills
/// up or a server that drops the connection does.
///
/// Everything else goes to the memory file system as it is; only this layer is registered, under
/// the memory file system's scheme.
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
        /// Asking for the folder above (it fails by answering nil).
        case parent
        /// Looking at one item (it fails by answering nil).
        case item
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
        let path: String

        init(_ inner: any FileReader, _ owner: CoverageSmallFiles, path: String) {
            (self.inner, self.owner, self.path) = (inner, owner, path)
        }

        func read(upToCount count: Int) throws -> Data? {
            try owner.check(.read, path)
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
    private var failingTimes: [Call: Int] = [:]
    private var beforeFailing: (@Sendable (Call) -> Void)?
    private var onEveryCall: (@Sendable (Call) -> Void)?
    private var extraCapabilities: FileSystemCapabilities = []
    private var isServer = false
    private var isWatching = false
    private var watchers: [@MainActor @Sendable ([URL]) -> Void] = []
    private var attributeChanges: [String] = []
    private var trashedPaths: [String] = []
    private var rootIsNameless = false
    private var pathsThatFail: Set<String> = []

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

    /// Called on the calling thread at every call that can be made to fail, before it is
    /// carried out or fails: for a test that wants something to happen at that moment.
    public var onCall: (@Sendable (Call) -> Void)? {
        get { lock.withLock { onEveryCall } }
        set { lock.withLock { onEveryCall = newValue } }
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

    /// Whether folders can be watched (`watch` gives a token); false at first.
    public var watches: Bool {
        get { lock.withLock { isWatching } }
        set { lock.withLock { isWatching = newValue } }
    }

    /// How many watches were started.
    public var watchCount: Int { lock.withLock { watchers.count } }

    /// Whether the root is given without a name, as some servers give theirs; false at first.
    public var namesRootEmpty: Bool {
        get { lock.withLock { rootIsNameless } }
        set { lock.withLock { rootIsNameless = newValue } }
    }

    /// The paths that went to the Trash, in order.
    public var trashed: [String] { lock.withLock { trashedPaths } }

    /// The paths whose date or permissions were changed, in order (the memory file system
    /// keeps neither change).
    public var changedAttributes: [String] { lock.withLock { attributeChanges } }

    /// The paths whose calls fail, whatever the call; none at first.
    public var failingPaths: Set<String> {
        get { lock.withLock { pathsThatFail } }
        set { lock.withLock { pathsThatFail = newValue } }
    }

    /// A layer over `base`, failing nothing yet.
    public init(_ base: MemoryFileSystem) {
        self.base = base
    }

    /// Makes the next `times` calls of `call` fail; the ones after succeed again.
    public func fail(_ call: Call, times: Int) {
        lock.withLock { failingTimes[call] = times }
    }

    /// Throws when `call` (on `path`, when it is about one) fails, after `onFailure`; `onCall`
    /// hears of it first.
    private func check(_ call: Call, _ path: String? = nil) throws {
        onCall?(call)
        let (isFailing, hook) = lock.withLock { () -> (Bool, (@Sendable (Call) -> Void)?) in
            var isFailing = failing.contains(call) || path.map(pathsThatFail.contains) == true
            if !isFailing, let left = failingTimes[call], left > 0 {
                failingTimes[call] = left - 1
                isFailing = true
            }
            return (isFailing, beforeFailing)
        }
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

    /// The memory file system's item, unless `.item` fails.
    public func item(at url: URL) -> FileItem? {
        do {
            try check(.item)
        } catch {
            return nil
        }
        return named(base.item(at: url))
    }

    /// The memory file system's item, unless `.item` fails or the flag is set.
    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        do {
            try check(.item)
        } catch {
            return nil
        }
        return named(base.item(at: url, cancellation: cancellation))
    }

    /// The item as this layer names it: the root without a name while `namesRootEmpty` is set.
    private func named(_ item: FileItem?) -> FileItem? {
        guard let item, item.url.path == "/", namesRootEmpty else {
            return item
        }
        return FileItem(url: item.url, name: "", kind: item.kind, stat: item.stat)
    }

    /// The memory file system's parent, unless `.parent` fails.
    public func parent(of directory: URL) -> URL? {
        do {
            try check(.parent)
        } catch {
            return nil
        }
        return base.parent(of: directory)
    }

    /// A token for the watch while `watches` is set; nil otherwise. `report` calls `onChange`.
    @preconcurrency
    public func watch(_: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (any WatchToken)? {
        lock.withLock {
            guard isWatching else {
                return nil
            }
            watchers.append(onChange)
            return Shared(watchers.count)
        }
    }

    /// Tells every watch that `directories` changed, as the file system would.
    ///
    /// Main thread.
    @preconcurrency
    @MainActor
    public func report(_ directories: [URL]) {
        let current = lock.withLock { watchers }
        for watcher in current {
            watcher(directories)
        }
    }

    /// A reader of the memory file, unless `.open` fails.
    public func read(_ url: URL) throws -> any FileReader {
        try check(.open, url.path)
        return Reader(try base.read(url), self, path: url.path)
    }

    /// A reader of the memory file, unless `.open` fails or the flag is set.
    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        try check(.open, url.path)
        return Reader(try base.read(url, cancellation: cancellation), self, path: url.path)
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

    /// Takes the item away as the Trash would, unless `.remove` fails.
    public func trash(_ url: URL) throws {
        try check(.remove)
        base.removeTree(url.path)
        lock.withLock { trashedPaths.append(url.path) }
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

    /// Notes a change of the date or permissions, unless `.setAttributes` fails.
    public func setAttributes(_: FileAttributes, of url: URL) throws {
        try check(.setAttributes)
        lock.withLock { attributeChanges.append(url.path) }
    }

    /// The memory file system's metadata copy.
    public func copyMetadata(from source: URL, to destination: URL) throws {
        try base.copyMetadata(from: source, to: destination)
    }

    /// Makes durable what was written, as the memory file system records it.
    public func commit(_ url: URL, cancellation: CancellationFlag) throws {
        try base.commit(url, cancellation: cancellation)
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
