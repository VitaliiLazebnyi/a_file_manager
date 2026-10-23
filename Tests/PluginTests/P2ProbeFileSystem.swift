import AFMContracts
import AFMKernel
import Foundation
import TestSupport

/// A file system over memory that notes how it is called, and can be made to misbehave the
/// way a server does.
///
/// Every call is forwarded to `base`. Unchecked: what it records is guarded by `lock`; its switches
/// are set by the test before use.
internal final class P2ProbeFileSystem: FileSystemProvider, @unchecked Sendable {
    /// A writer that writes through and then fails when it is closed with contents.
    ///
    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class FailingWriter: FileWriter, @unchecked Sendable {
        let inner: any FileWriter
        let failure: any Error
        var wrote = false

        init(_ inner: any FileWriter, _ failure: any Error) { (self.inner, self.failure) = (inner, failure) }

        func write(_ data: Data) throws {
            wrote = true
            try inner.write(data)
        }
        func close(attributes: FileAttributes) throws {
            try inner.close(attributes: attributes)
            if wrote {
                wrote = false
                throw failure
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The memory file system every call goes on to.
    internal let base: MemoryFileSystem
    /// The scheme of `base`.
    internal var scheme: String { base.scheme }
    /// What `base` can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    /// The probe reads paths from the root of its scheme, as `base` does.
    internal let readsRootedPaths = true

    private let lock = NSLock()
    private var withFlag: [String] = []
    private var withoutFlag: [String] = []
    private var readPaths: [String] = []
    private var listedPaths: [String] = []
    private var shown = 0
    /// What `readOrder(of:)` answers; nil leaves the order.
    internal var order: (([URL]) -> [URL])?
    /// When set, `setQuarantine` fails with it.
    internal var quarantineFailure: (any Error)?
    /// When set, every writer fails with it when it is closed with contents.
    internal var writeFailure: (any Error)?
    /// A removal that was given a flag does not come back until the flag is set.
    internal var stallsRemovals = false
    /// Called when such a removal starts to wait.
    internal var onStalledRemoval: (() -> Void)?

    /// The changing calls that came with a cancellation flag, by name, in the order they came.
    internal var flagged: [String] { lock.withLock { withFlag } }
    /// The changing calls that came without a cancellation flag, by name, in the order they came.
    internal var unflagged: [String] { lock.withLock { withoutFlag } }
    /// The paths that were opened for reading, in that order.
    internal var reads: [String] { lock.withLock { readPaths } }
    /// How many times a path was turned into text for display.
    internal var displayed: Int { lock.withLock { shown } }

    /// A probe over a fresh memory file system with the scheme `probe`.
    internal init() {
        base = MemoryFileSystem(scheme: "probe")
    }

    /// How many times the folder at `path` was listed.
    internal func listings(of path: String) -> Int { lock.withLock { listedPaths.filter { $0 == path }.count } }

    private func note(_ call: String, flag: CancellationFlag?) throws {
        lock.withLock { flag == nil ? withoutFlag.append(call) : withFlag.append(call) }
        if flag?.isCancelled == true { throw CocoaError(.userCancelled) }
    }

    /// What `base` can do at `url`.
    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }
    /// Notes the listing and lists the folder in `base`.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        lock.withLock { listedPaths.append(directory.path) }
        return try base.list(directory, showHidden: showHidden)
    }
    /// Notes the listing and lists the folder in `base`, until `cancellation` is set.
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        lock.withLock { listedPaths.append(directory.path) }
        return try base.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    /// The entry of `base` at `url`, if there is one.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }
    /// The folder above `directory` in `base`.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    /// Notes the path and opens the file of `base` for reading.
    internal func read(_ url: URL) throws -> any FileReader {
        lock.withLock { readPaths.append(url.path) }
        return try base.read(url)
    }
    /// Notes the path and opens the file of `base` for reading, until `cancellation` is set.
    internal func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        lock.withLock { readPaths.append(url.path) }
        return try base.read(url, cancellation: cancellation)
    }

    /// A writer into `base`; one that fails on closing while `writeFailure` is set.
    internal func write(_ url: URL) throws -> any FileWriter {
        let writer = try base.write(url)
        return writeFailure.map { FailingWriter(writer, $0) } ?? writer
    }
    /// A writer that adds to the file of `base` at `offset`.
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        try base.append(to: url, at: offset, cancellation: cancellation)
    }
    /// Copies within `base`.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }
    /// Commits the writes of `base` that wait below `url`.
    internal func commit(_ url: URL, cancellation: CancellationFlag) throws {
        try base.commit(url, cancellation: cancellation)
    }
    /// The origin mark `base` gives its files.
    internal func quarantine(of url: URL) -> Data? { base.quarantine(of: url) }
    /// Counts the call and answers with the path `base` shows.
    internal func displayPath(_ url: URL) -> String {
        lock.withLock { shown += 1 }
        return base.displayPath(url)
    }
    /// The location `base` reads from `text`.
    internal func location(from text: String) -> URL? { base.location(from: text) }
    /// The volume `base` says `url` is on.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
    /// The order `order` gives, or `urls` as they are.
    internal func readOrder(of urls: [URL]) -> [URL] { order?(urls) ?? urls }

    // The calls that change something, with a flag and without.

    /// Notes the call without a flag and makes the folder.
    internal func createDirectory(at url: URL) throws {
        try note("createDirectory", flag: nil)
        base.createDirectory(at: url)
    }
    /// Notes the call with its flag and makes the folder.
    internal func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try note("createDirectory", flag: cancellation)
        base.createDirectory(at: url)
    }
    /// Notes the call with its flag and makes the folder; when `exclusive`, fails if something is there.
    internal func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        try note("createDirectory", flag: cancellation)
        if exclusive, base.item(at: url) != nil { throw FileSystemError.alreadyExists(base.displayPath(url)) }
        base.createDirectory(at: url)
    }
    /// Notes the call without a flag and removes the entry.
    internal func remove(_ url: URL) throws {
        try note("remove", flag: nil)
        try base.remove(url)
    }
    /// Notes the call with its flag and removes the entry; with `stallsRemovals` set it first waits for the flag.
    internal func remove(_ url: URL, cancellation: CancellationFlag) throws {
        if stallsRemovals {
            onStalledRemoval?()
            let gate = DispatchSemaphore(value: 0)
            let waiting = cancellation.onCancel { gate.signal() }
            withExtendedLifetime(waiting) { gate.wait() }
        }
        try note("remove", flag: cancellation)
        try base.remove(url)
    }
    /// Notes the call without a flag and moves the entry.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try note("move", flag: nil)
        try base.move(source, to: destination, replacing: replacing)
    }
    /// Notes the call with its flag and moves the entry.
    internal func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try note("move", flag: cancellation)
        try base.move(source, to: destination, replacing: replacing)
    }
    /// Notes the call without a flag; the attributes are not kept.
    internal func setAttributes(_: FileAttributes, of _: URL) throws { try note("setAttributes", flag: nil) }
    /// Notes the call with its flag; the attributes are not kept.
    internal func setAttributes(_: FileAttributes, of _: URL, cancellation: CancellationFlag) throws {
        try note("setAttributes", flag: cancellation)
    }
    /// Notes the call without a flag; nothing is copied.
    internal func copyMetadata(from _: URL, to _: URL) throws { try note("copyMetadata", flag: nil) }
    /// Notes the call with its flag; nothing is copied.
    internal func copyMetadata(from _: URL, to _: URL, cancellation: CancellationFlag) throws {
        try note("copyMetadata", flag: cancellation)
    }
    /// Notes the call without a flag and marks the file, or fails with `quarantineFailure`.
    internal func setQuarantine(_ value: Data, of url: URL) throws {
        try note("setQuarantine", flag: nil)
        if let quarantineFailure { throw quarantineFailure }
        try base.setQuarantine(value, of: url)
    }
    /// Notes the call with its flag and marks the file, or fails with `quarantineFailure`.
    internal func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        try note("setQuarantine", flag: cancellation)
        if let quarantineFailure { throw quarantineFailure }
        try base.setQuarantine(value, of: url)
    }

    deinit {
        // Nothing to release.
    }
}
