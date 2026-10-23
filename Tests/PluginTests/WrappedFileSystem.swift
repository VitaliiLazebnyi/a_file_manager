import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

/// A file system that passes everything on to a `MemoryFileSystem` and can misbehave on the
/// way: damage what is written, take its time, and count how many copies run at once.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class WrappedFileSystem: FileSystemProvider, @unchecked Sendable {
    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class Writer: FileWriter, @unchecked Sendable {
        let inner: any FileWriter
        let owner: WrappedFileSystem
        var first = true

        init(_ inner: any FileWriter, _ owner: WrappedFileSystem) {
            self.inner = inner
            self.owner = owner
        }

        func write(_ data: Data) throws {
            if owner.delay > 0 { Thread.sleep(forTimeInterval: owner.delay) }
            var data = data
            if owner.corruptsWrites, first, !data.isEmpty { data[data.startIndex] = data[data.startIndex] ^ 0xFF }
            first = false
            try inner.write(data)
        }

        func close(attributes: FileAttributes) throws {
            owner.ended()
            try inner.close(attributes: attributes)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The file system everything is passed on to.
    internal let base: MemoryFileSystem
    /// The scheme of `base`, so that its locations are this file system's.
    internal let scheme: String
    /// What `base` can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    /// Every stream written here loses its first byte's value.
    internal var corruptsWrites = false
    /// How long a copy inside this file system and each written block take.
    internal var delay: TimeInterval = 0
    private let lock = NSLock()
    private var running = 0
    private var mostAtOnce = 0

    /// The largest number of files that were being written at the same time.
    internal var mostWritesAtOnce: Int { lock.withLock { mostAtOnce } }

    /// A file system in front of `base`, behaving well until a switch is set.
    internal init(_ base: MemoryFileSystem) {
        self.base = base
        scheme = base.scheme
    }

    private func began() {
        lock.withLock {
            running += 1
            mostAtOnce = max(mostAtOnce, running)
        }
    }
    private func ended() { lock.withLock { running -= 1 } }

    /// The entries of `directory` in `base`.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }
    /// The item at `url` in `base`.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }
    /// The folder above `directory` in `base`.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    /// A reader of the file at `url` in `base`.
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }
    /// Makes the folder at `url` in `base`.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }
    /// A writer into the file at `url` in `base` that delays or damages what it writes as the switches say.
    internal func write(_ url: URL) throws -> any FileWriter {
        let writer = Writer(try base.write(url), self)
        began()
        return writer
    }
    /// Removes the item at `url` from `base`.
    internal func remove(_ url: URL) throws { try base.remove(url) }
    /// Moves an item inside `base`.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }
    /// Copies an item inside `base`, after `delay`, counted among the writes that run at once.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        began()
        defer { ended() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try base.copy(source, to: destination, progress: progress)
    }
    /// How `base` shows `url`.
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }
    /// The location `base` reads from a typed `text`.
    internal func location(from text: String) -> URL? { base.location(from: text) }
    /// The volume `base` names for `url`.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }

    deinit {
        // Nothing to release.
    }
}

/// The local disk plus a wrapped in-memory file system.
internal func makeWrappedFileSystems() -> (FileSystemRegistry, WrappedFileSystem) {
    let fileSystems = FileSystemRegistry()
    let wrapped = WrappedFileSystem(MemoryFileSystem())
    fileSystems.register(LocalFileSystem())
    fileSystems.register(wrapped)
    return (fileSystems, wrapped)
}
