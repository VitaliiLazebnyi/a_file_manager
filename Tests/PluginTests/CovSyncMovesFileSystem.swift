import AFMKernel
import Foundation
import TestSupport

/// A memory file system (scheme `moves`) whose moves and removals a test can make fail: for
/// what a run does when a file cannot be replaced in one step, or a folder cannot go.
///
/// Unchecked: the hooks are guarded by `lock`; `base` is safe from any thread.
internal final class CovSyncMovesFileSystem: FileSystemProvider, @unchecked Sendable {
    /// A reader that does not stop when it is interrupted, as some servers' do not.
    ///
    /// Unchecked: used by one thread at a time, as `FileReader` allows.
    private final class StubbornReader: FileReader, @unchecked Sendable {
        private let base: any FileReader

        init(_ base: any FileReader) {
            self.base = base
        }

        func read(upToCount count: Int) throws -> Data? {
            try base.read(upToCount: count)
        }

        func seek(to offset: UInt64) throws {
            try base.seek(to: offset)
        }

        func interrupt() {
            // Reads on regardless.
        }

        func close() {
            base.close()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A writer that does not keep the date it is given, as some servers' do not.
    ///
    /// Unchecked: used by one thread at a time, as `FileWriter` allows.
    private final class DatelessWriter: FileWriter, @unchecked Sendable {
        private let base: any FileWriter

        init(_ base: any FileWriter) {
            self.base = base
        }

        func write(_ data: Data) throws {
            try base.write(data)
        }

        func close(attributes _: FileAttributes) throws {
            try base.close(attributes: FileAttributes())
        }

        func interrupt() {
            base.interrupt()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A writer that takes nothing.
    ///
    /// Unchecked: it holds nothing.
    private final class FailingWriter: FileWriter, @unchecked Sendable {
        func write(_: Data) throws {
            throw FileSystemError.notSupported("writing")
        }

        func close(attributes _: FileAttributes) {
            // Nothing was written.
        }

        func interrupt() {
            // Nothing to stop.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The memory file system underneath, which holds the files.
    internal let base = MemoryFileSystem(scheme: "moves")
    /// Paths from the root are this file system's own.
    internal let readsRootedPaths = true
    private let lock = NSLock()
    private var moveHook: @Sendable (_ source: URL, _ destination: URL, _ replacing: Bool) throws -> Void = { _, _, _ in
        // Every move goes through.
    }
    private var unremovable: Set<String> = []
    private var writes = true
    private var reads = true
    private var writtenDates = true
    private var settableDates = true
    private var setDates: [String: Date] = [:]

    /// `moves`.
    internal var scheme: String { base.scheme }
    /// What the memory file system can do.
    internal var capabilities: FileSystemCapabilities { base.capabilities }

    /// Nothing fails yet.
    internal init() {
        // The test says what fails.
    }

    /// Runs `hook` before every move; a move it throws for does not happen.
    internal func beforeMoves(_ hook: @escaping @Sendable (URL, URL, Bool) throws -> Void) {
        lock.withLock { moveHook = hook }
    }

    /// From now on a file keeps no date when it is written; with `settable` false, also when it is set.
    internal func loseDates(settable: Bool) {
        lock.withLock {
            writtenDates = false
            settableDates = settable
        }
    }

    /// Every read fails from now on.
    internal func refuseReading() {
        lock.withLock { reads = false }
    }

    /// Every write fails from now on.
    internal func refuseWriting() {
        lock.withLock { writes = false }
    }

    /// Removing anything at these paths fails.
    internal func refuseRemoving(_ paths: Set<String>) {
        lock.withLock { unremovable = paths }
    }

    /// The memory file system's answer.
    internal func capabilities(for url: URL) -> FileSystemCapabilities {
        base.capabilities(for: url)
    }

    /// The memory file system's listing.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The memory file system's answer.
    internal func item(at url: URL) -> FileItem? {
        base.item(at: url)
    }

    /// The memory file system's answer.
    internal func parent(of directory: URL) -> URL? {
        base.parent(of: directory)
    }

    /// The memory file system's reader, which an interrupt does not stop; none once reads are refused.
    internal func read(_ url: URL) throws -> any FileReader {
        guard lock.withLock({ reads }) else {
            throw FileSystemError.notSupported("reading")
        }
        return StubbornReader(try base.read(url))
    }

    /// The memory file system's writer; one that fails once writes are refused, one that keeps
    /// no date once dates are lost.
    internal func write(_ url: URL) throws -> any FileWriter {
        let (accepts, keepsDates) = lock.withLock { (writes, writtenDates) }
        guard accepts else {
            return FailingWriter()
        }
        let writer = try base.write(url)
        return keepsDates ? writer : DatelessWriter(writer)
    }

    /// Removes from the memory file system, unless the path is refused.
    internal func remove(_ url: URL) throws {
        let refused = lock.withLock { unremovable.contains(url.path) }
        if refused { throw FileSystemError.notSupported("removing \(url.path)") }
        try base.remove(url)
    }

    /// Runs the hook, then moves in the memory file system.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        let hook = lock.withLock { moveHook }
        try hook(source, destination, replacing)
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies in the memory file system to the end, whatever the progress says (a copy that
    /// cannot be stopped half-way).
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination) { bytes in
            _ = progress(bytes)
            return true
        }
    }

    /// Notes the date set (the memory file system keeps the dates of writes only), or fails
    /// when dates cannot be set.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try lock.withLock {
            guard settableDates else { throw FileSystemError.notSupported("dates") }
            setDates[url.path] = attributes.modified
        }
    }

    /// The date last set for the item at `path`.
    internal func dateSet(at path: String) -> Date? {
        lock.withLock { setDates[path] }
    }

    /// Moves to the Trash: removes from the memory file system.
    internal func trash(_ url: URL) throws {
        try remove(url)
    }

    /// The memory file system's notation.
    internal func displayPath(_ url: URL) -> String {
        base.displayPath(url)
    }

    /// Reads the memory file system's notation.
    internal func location(from text: String) -> URL? {
        base.location(from: text)
    }

    /// The memory file system's volume.
    internal func volume(of url: URL) -> VolumeInfo? {
        base.volume(of: url)
    }

    /// Makes a folder in the memory file system.
    internal func createDirectory(at url: URL) {
        base.createDirectory(at: url)
    }

    deinit {
        // Nothing to release.
    }
}
