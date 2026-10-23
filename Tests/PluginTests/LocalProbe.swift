import AFMKernel
import Foundation
import LocalFileSystemPlugin

/// The local disk behind a layer that makes copies take a moment, counts how many run at once
/// and per file, and lets chosen removals fail once.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class LocalProbe: FileSystemProvider, @unchecked Sendable {
    /// The disk every call goes to.
    private let local = LocalFileSystem()

    /// The local disk's scheme, so the probe stands in for it.
    internal var scheme: String { local.scheme }

    /// The local disk's capabilities.
    internal var capabilities: FileSystemCapabilities { local.capabilities }

    /// Names whose first removal fails.
    internal var failsOnce: Set<String> = []

    /// Guards the counters below.
    private let lock = NSLock()

    /// The copies running now.
    private var running = 0

    /// The most copies that ran at once.
    private var most = 0

    /// How often each file name was copied.
    private var copied: [String: Int] = [:]

    /// How many removals were made to fail.
    private var removalsFailed = 0

    /// The most copies that ran at the same time.
    internal var mostCopiesAtOnce: Int { lock.withLock { most } }

    /// How many copies ran in all.
    internal var totalCopies: Int { lock.withLock { copied.values.reduce(0, +) } }

    /// How many removals failed because their name was in `failsOnce`.
    internal var failedRemovals: Int { lock.withLock { removalsFailed } }

    /// How often the file of that name was copied.
    internal func copies(of name: String) -> Int { lock.withLock { copied[name] ?? 0 } }

    /// The disk's listing of the directory.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try local.list(directory, showHidden: showHidden)
    }

    /// The disk's listing of the directory, ended early once `cancellation` is set.
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try local.list(directory, showHidden: showHidden, cancellation: cancellation)
    }

    /// The disk's entry at `url`.
    internal func item(at url: URL) -> FileItem? { local.item(at: url) }

    /// The folder above, as the disk sees it.
    internal func parent(of directory: URL) -> URL? { local.parent(of: directory) }

    /// Opens the file on the disk for reading.
    internal func read(_ url: URL) throws -> any FileReader { try local.read(url) }

    /// Makes the folder on the disk.
    internal func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }

    /// Creates the file on the disk for writing.
    internal func write(_ url: URL) throws -> any FileWriter { try local.write(url) }

    /// Opens the file on the disk to continue it.
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        try local.append(to: url, at: offset, cancellation: cancellation)
    }

    /// Removes the item from the disk, or fails once for a name in `failsOnce`.
    internal func remove(_ url: URL) throws {
        let fails: Bool = lock.withLock {
            guard failsOnce.remove(url.lastPathComponent) != nil else {
                return false
            }
            removalsFailed += 1
            return true
        }
        if fails { throw CocoaError(.fileWriteNoPermission) }
        try local.remove(url)
    }

    /// Moves the item to the disk's Trash.
    internal func trash(_ url: URL) throws { try local.trash(url) }

    /// Renames on the disk.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try local.move(source, to: destination, replacing: replacing)
    }

    /// Copies on the disk after a short wait, counting the copy and how many run at once.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        lock.withLock {
            running += 1
            most = max(most, running)
            copied[source.lastPathComponent, default: 0] += 1
        }
        defer { lock.withLock { running -= 1 } }
        // Long enough for the copies of a pool to overlap.
        Thread.sleep(forTimeInterval: 0.03)
        try local.copy(source, to: destination, progress: progress)
    }

    /// Sets the date and permissions on the disk.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try local.setAttributes(attributes, of: url)
    }

    /// Carries the rest of the metadata on the disk.
    internal func copyMetadata(from source: URL, to destination: URL) throws {
        try local.copyMetadata(from: source, to: destination)
    }

    /// The disk's quarantine mark of the item.
    internal func quarantine(of url: URL) -> Data? { local.quarantine(of: url) }

    /// Sets the quarantine mark on the disk.
    internal func setQuarantine(_ value: Data, of url: URL) throws { try local.setQuarantine(value, of: url) }

    /// The path as the disk shows it.
    internal func displayPath(_ url: URL) -> String { local.displayPath(url) }

    /// The disk's volume that holds the item.
    internal func volume(of url: URL) -> VolumeInfo? { local.volume(of: url) }

    deinit {
        // Nothing to release.
    }
}
