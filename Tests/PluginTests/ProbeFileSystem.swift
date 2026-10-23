import AFMKernel
import Foundation
import TestSupport

/// A `MemoryFileSystem` behind a layer that tells a test what a job is doing to it: it signals
/// when a read, write, listing or commit begins, and counts the calls that matter.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class ProbeFileSystem: FileSystemProvider, @unchecked Sendable {
    /// A reader of the base that calls `onRead` before each read.
    private final class Reader: FileReader {
        let inner: any FileReader, owner: ProbeFileSystem

        init(_ inner: any FileReader, _ owner: ProbeFileSystem) { (self.inner, self.owner) = (inner, owner) }

        func read(upToCount count: Int) throws -> Data? {
            owner.onRead?()
            return try inner.read(upToCount: count)
        }

        func seek(to offset: UInt64) throws { try inner.seek(to: offset) }

        func close() { inner.close() }

        func interrupt() { inner.interrupt() }

        deinit {
            // Nothing to release.
        }
    }

    /// A writer of the base that calls `onWrite` before each write.
    private final class Writer: FileWriter {
        let inner: any FileWriter, owner: ProbeFileSystem

        init(_ inner: any FileWriter, _ owner: ProbeFileSystem) { (self.inner, self.owner) = (inner, owner) }

        func write(_ data: Data) throws {
            owner.onWrite?()
            try inner.write(data)
        }

        func close(attributes: FileAttributes) throws { try inner.close(attributes: attributes) }

        func interrupt() { inner.interrupt() }

        deinit {
            // Nothing to release.
        }
    }

    /// The memory file system every call goes to.
    internal let base: MemoryFileSystem

    /// The base's scheme.
    internal var scheme: String { base.scheme }

    /// The base's capabilities as a whole.
    internal var capabilities: FileSystemCapabilities { base.capabilities }

    /// Called when a read is entered (before it may wait).
    internal var onRead: (() -> Void)?

    /// Called when a write is entered (before it may wait).
    internal var onWrite: (() -> Void)?

    /// Called when a listing with a cancellation flag is entered (before it may wait).
    internal var onList: (() -> Void)?

    /// Called when a commit is entered (before it may wait).
    internal var onCommit: (() -> Void)?

    /// Called when a move begins.
    internal var onMove: (() -> Void)?

    /// Claimed on top of what the base can do, as a server without a session claims `.append`
    /// that its connection then cannot keep.
    internal var claims: FileSystemCapabilities = []

    /// Guards `calls`.
    private let lock = NSLock()

    /// How often each counted call was made, by name.
    private var calls: [String: Int] = [:]

    /// A probe in front of `base`.
    internal init(_ base: MemoryFileSystem) { self.base = base }

    /// How often the call of that name was made: `list <path>`, `write`, `append` or `quarantine`.
    internal func count(of name: String) -> Int { lock.withLock { calls[name] ?? 0 } }

    /// What the base can do at `url`, with `claims` added.
    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url).union(claims) }

    /// The base's listing, counted.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        count("list " + directory.path)
        return try base.list(directory, showHidden: showHidden)
    }

    /// The base's listing, counted, after calling `onList`.
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        count("list " + directory.path)
        onList?()
        return try base.list(directory, showHidden: showHidden, cancellation: cancellation)
    }

    /// The base's item at `url`.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The folder above, as the base sees it.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// Opens the file of the base with a reader that calls `onRead`.
    internal func read(_ url: URL) throws -> any FileReader { Reader(try base.read(url), self) }

    /// Opens the file of the base with a reader that calls `onRead`, ended early once `cancellation` is set.
    internal func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        Reader(try base.read(url, cancellation: cancellation), self)
    }

    /// Makes the folder in the base.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    /// Creates the file in the base with a writer that calls `onWrite`; counted as `write`.
    internal func write(_ url: URL) throws -> any FileWriter {
        count("write")
        return Writer(try base.write(url), self)
    }

    /// Creates the file in the base with a writer that calls `onWrite`; counted as `write`.
    internal func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        count("write")
        return Writer(try base.write(url, cancellation: cancellation), self)
    }

    /// Opens the file of the base to continue it, with a writer that calls `onWrite`; counted as `append`.
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        count("append")
        return Writer(try base.append(to: url, at: offset, cancellation: cancellation), self)
    }

    /// Removes the item from the base.
    internal func remove(_ url: URL) throws { try base.remove(url) }

    /// Calls `onMove`, then renames in the base.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        onMove?()
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies within the base.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    /// Carries metadata within the base.
    internal func copyMetadata(from source: URL, to destination: URL) throws {
        try base.copyMetadata(from: source, to: destination)
    }

    /// Calls `onCommit`, then commits the base.
    internal func commit(_ url: URL, cancellation: CancellationFlag) throws {
        onCommit?()
        try base.commit(url, cancellation: cancellation)
    }

    /// The base's quarantine mark of the item; counted as `quarantine`.
    internal func quarantine(of url: URL) -> Data? {
        count("quarantine")
        return base.quarantine(of: url)
    }

    /// Sets the quarantine mark in the base.
    internal func setQuarantine(_ value: Data, of url: URL) throws { try base.setQuarantine(value, of: url) }

    /// The path as the base shows it.
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }

    /// The location a typed path stands for, as the base reads it.
    internal func location(from text: String) -> URL? { base.location(from: text) }

    /// The base's volume.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }

    /// Counts one call of that name.
    private func count(_ name: String) { lock.withLock { calls[name, default: 0] += 1 } }

    deinit {
        // Nothing to release.
    }
}
