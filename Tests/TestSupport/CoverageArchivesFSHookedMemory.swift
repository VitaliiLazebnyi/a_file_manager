public import AFMKernel
public import Foundation

/// A memory file system (scheme `hooked`) that runs a hook, once (or for every file opened),
/// where a file is looked at or read, and counts how often files were opened for reading: for what happens to the code
/// that reads it while it looks or reads.
///
/// Unchecked: the hooks and the count are guarded by `lock`; `base` is safe from any thread.
public final class CoverageArchivesFSHookedMemory: FileSystemProvider, @unchecked Sendable {
    /// A reader that runs a hook in its first read, before it hands the block over.
    ///
    /// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` is handed
    /// to the reader below, which is safe from any thread.
    private final class Reader: FileReader, @unchecked Sendable {
        private let base: any FileReader
        private var hook: (@Sendable () -> Void)?

        init(_ base: any FileReader, hook: (@Sendable () -> Void)?) {
            self.base = base
            self.hook = hook
        }

        func read(upToCount count: Int) throws -> Data? {
            let block = try base.read(upToCount: count)
            let first = hook
            hook = nil
            first?()
            return block
        }

        func seek(to offset: UInt64) throws {
            try base.seek(to: offset)
        }

        func interrupt() {
            base.interrupt()
        }

        func close() {
            base.close()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The memory file system underneath, which holds the files.
    public let base = MemoryFileSystem(scheme: "hooked")
    /// Paths from the root are this file system's own.
    public let readsRootedPaths = true
    private let lock = NSLock()
    private var itemHook: (@Sendable () -> Void)?
    private var readHook: (@Sendable () -> Void)?
    /// Whether `readHook` stays for the files opened after the next one.
    private var keepsReadHook = false
    private var openings = 0

    /// `hooked`.
    public var scheme: String { base.scheme }
    /// What the memory file system can do.
    public var capabilities: FileSystemCapabilities { base.capabilities }
    /// How often a file was opened for reading.
    public var opened: Int { lock.withLock { openings } }

    /// Nothing is hooked yet.
    public init() {
        // The hooks are set by the test.
    }

    /// Puts a file holding `data` at `path` on `memory`, in place of what was there, making
    /// the folders above it; returns its location.
    @discardableResult
    public static func put(_ data: Data, at path: String, on memory: MemoryFileSystem) throws -> URL {
        let url = memory.url(path)
        memory.addDirectory(url.deletingLastPathComponent().path)
        if memory.exists(path) {
            try memory.remove(url)
        }
        let writer = try memory.write(url)
        try writer.write(data)
        try writer.close(attributes: FileAttributes())
        return url
    }

    /// Runs `hook` in the next look at a file, before it is answered.
    @preconcurrency
    public func onNextItem(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { itemHook = hook }
    }

    /// Runs `hook` in the first read of the next file that is opened, after the block was
    /// read and before it is handed over.
    @preconcurrency
    public func onNextRead(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { (readHook, keepsReadHook) = (hook, false) }
    }

    /// Runs `hook` in the first read of every file that is opened from now on, after the block
    /// was read and before it is handed over.
    @preconcurrency
    public func onEveryRead(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { (readHook, keepsReadHook) = (hook, true) }
    }

    /// The memory file system's answer.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        base.capabilities(for: url)
    }

    /// The memory file system's listing.
    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// Runs the hook of the next look, if any, then asks the memory file system.
    public func item(at url: URL) -> FileItem? {
        let hook = lock.withLock {
            defer { itemHook = nil }
            return itemHook
        }
        hook?()
        return base.item(at: url)
    }

    /// The memory file system's answer.
    public func parent(of directory: URL) -> URL? {
        base.parent(of: directory)
    }

    /// A reader of the memory file system's file that runs the hook of the next read, if any.
    public func read(_ url: URL) throws -> any FileReader {
        let hook = lock.withLock {
            openings += 1
            defer { if !keepsReadHook { readHook = nil } }
            return readHook
        }
        return Reader(try base.read(url), hook: hook)
    }

    /// The memory file system's writer.
    public func write(_ url: URL) throws -> any FileWriter {
        try base.write(url)
    }

    /// Removes from the memory file system.
    public func remove(_ url: URL) throws {
        try base.remove(url)
    }

    /// Moves in the memory file system.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies in the memory file system.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Changes the attributes in the memory file system.
    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try base.setAttributes(attributes, of: url)
    }

    /// The memory file system's notation.
    public func displayPath(_ url: URL) -> String {
        base.displayPath(url)
    }

    /// Reads the memory file system's notation.
    public func location(from text: String) -> URL? {
        base.location(from: text)
    }

    /// The memory file system's volume.
    public func volume(of url: URL) -> VolumeInfo? {
        base.volume(of: url)
    }

    /// Makes a folder in the memory file system.
    public func createDirectory(at url: URL) {
        base.createDirectory(at: url)
    }

    deinit {
        // Nothing to release.
    }
}
