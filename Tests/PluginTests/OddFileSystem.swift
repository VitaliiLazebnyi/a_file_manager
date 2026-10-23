import AFMKernel
import Foundation
import TestSupport

/// A file system over memory that can be told to misbehave the way servers and shares do:
/// list names that lead out of their folder, refuse the Trash in different ways, fail a removal.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class OddFileSystem: FileSystemProvider, @unchecked Sendable {
    /// The memory file system that holds the real items.
    internal let base = MemoryFileSystem(scheme: "odd")

    /// The memory file system's scheme, `odd`.
    internal var scheme: String { base.scheme }

    /// Writing and a Trash, so that deleting asks the Trash first.
    internal var capabilities: FileSystemCapabilities { [.write, .trash] }

    /// Guards what is recorded below.
    private let lock = NSLock()

    /// The names listed in a folder, by path, besides its real items.
    private var hostile: [String: [String]] = [:]

    /// How many of the next removals fail.
    private var failures = 0

    /// Every item a removal was asked for, in order.
    private var removedURLs: [URL] = []

    /// Every item the Trash was asked for, in order.
    private var trashed: [URL] = []

    /// What `trash` throws; nil trashes for real.
    internal var trashError: (any Error)?

    /// The items removals were asked for, failed ones too.
    internal var removed: [URL] { lock.withLock { removedURLs } }

    /// The items the Trash was asked for, refused ones too.
    internal var trashedItems: [URL] { lock.withLock { trashed } }

    /// Makes the listing of `directory` show these names as well, each as a small file.
    internal func addHostile(names: [String], in directory: String) { lock.withLock { hostile[directory] = names } }

    /// Makes the next `count` removals fail.
    internal func failNextRemovals(_ count: Int) { lock.withLock { failures = count } }

    /// The real items of the folder, then the hostile names given for it.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        var items = try base.list(directory, showHidden: showHidden)
        for (index, name) in (lock.withLock { hostile[directory.path] } ?? []).enumerated() {
            items.append(
                FileItem(url: directory.appendingPathComponent("hostile\(index)"), name: name, stat: .init(size: 4))
            )
        }
        return items
    }

    /// The item at `url`; an entry behind a hostile name is a file of 4 bytes.
    internal func item(at url: URL) -> FileItem? {
        if url.lastPathComponent.hasPrefix("hostile") {
            return FileItem(url: url, name: url.lastPathComponent, stat: .init(size: 4))
        }
        return base.item(at: url)
    }

    /// The folder above, as the memory file system sees it.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// Opens the file; an entry behind a hostile name reads `evil`.
    internal func read(_ url: URL) throws -> any FileReader {
        if url.lastPathComponent.hasPrefix("hostile") {
            return try base.read(base.addFile("/hostile-data", "evil"))
        }
        return try base.read(url)
    }

    /// Makes the folder in memory.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    /// Creates the file in memory for writing.
    internal func write(_ url: URL) throws -> any FileWriter { try base.write(url) }

    /// Records the removal and fails it while failures are due; otherwise removes the item.
    internal func remove(_ url: URL) throws {
        let fails: Bool = lock.withLock {
            removedURLs.append(url)
            if failures > 0 {
                failures -= 1
                return true
            }
            return false
        }
        if fails { throw CocoaError(.fileWriteUnknown) }
        try base.remove(url)
    }

    /// Records the request and throws `trashError` when one is set; otherwise removes the item.
    internal func trash(_ url: URL) throws {
        lock.withLock { trashed.append(url) }
        if let trashError { throw trashError }
        try base.remove(url)
    }

    /// Renames in memory.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Never copies by itself, so the job streams every file.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.crossesVolumes
    }

    /// The path as the memory file system shows it.
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }

    /// The location a typed path stands for, as the memory file system reads it.
    internal func location(from text: String) -> URL? { base.location(from: text) }

    /// The memory file system's volume.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }

    deinit {
        // Nothing to release.
    }
}
