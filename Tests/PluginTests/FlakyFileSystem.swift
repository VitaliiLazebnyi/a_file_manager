import AFMKernel
import Foundation
import TestSupport

/// A file system over memory whose reads can be made to fail or to cancel half-way, the way a
/// connection that breaks does.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class FlakyFileSystem: FileSystemProvider, @unchecked Sendable {
    /// The error a read that was made to fail throws.
    internal struct Broken: LocalizedError {
        /// What the user would be told: that the connection broke.
        internal var errorDescription: String? { "the connection broke" }
    }

    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class Reader: FileReader, @unchecked Sendable {
        let inner: any FileReader
        let fails: Bool
        let hook: (() -> Void)?
        var blocks = 0

        init(_ inner: any FileReader, fails: Bool, hook: (() -> Void)?) {
            (self.inner, self.fails, self.hook) = (inner, fails, hook)
        }

        func read(upToCount count: Int) throws -> Data? {
            if blocks == 1 {
                hook?()
                if fails { throw Broken() }
            }
            blocks += 1
            // Small blocks, so that a file has several.
            return try inner.read(upToCount: min(count, 4))
        }

        func seek(to offset: UInt64) throws { try inner.seek(to: offset) }

        func close() { inner.close() }

        deinit {
            // Nothing to release.
        }
    }

    /// The file system that holds the files.
    internal let base = MemoryFileSystem(scheme: "flaky")
    /// The scheme of `base`, so that its locations are this file system's.
    internal var scheme: String { base.scheme }
    /// Writing only: no copy inside the file system, so every copy is streamed through a reader.
    internal var capabilities: FileSystemCapabilities { [.write] }
    private let lock = NSLock()
    private var failures = 0
    /// Called once, after the first block of the next read.
    internal var afterFirstBlock: (() -> Void)?

    /// The next `count` readers fail after their first block.
    internal func failNextReads(_ count: Int) { lock.withLock { failures = count } }

    /// The entries of `directory` in `base`.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The item at `url` in `base`.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The folder above `directory` in `base`.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// A reader of the file in `base` that reads in small blocks, and fails or calls `afterFirstBlock` as set.
    internal func read(_ url: URL) throws -> any FileReader {
        let (fails, hook): (Bool, (() -> Void)?) = lock.withLock {
            defer { afterFirstBlock = nil }
            if failures > 0 {
                failures -= 1
                return (true, afterFirstBlock)
            }
            return (false, afterFirstBlock)
        }
        return Reader(try base.read(url), fails: fails, hook: hook)
    }

    /// Makes the folder at `url` in `base`.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    /// A writer into the file at `url` in `base`.
    internal func write(_ url: URL) throws -> any FileWriter { try base.write(url) }

    /// Removes the item at `url` from `base`.
    internal func remove(_ url: URL) throws { try base.remove(url) }

    /// Moves an item inside `base`.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Always throws `crossesVolumes`, so that the job streams the copy itself.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.crossesVolumes
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
