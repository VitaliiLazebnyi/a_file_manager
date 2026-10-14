import AFMKernel
import Foundation
import StressKit
import TestSupport

/// A MemoryFileSystem that claims `.deferredWrites`: it notes when each file was last written
/// (or renamed into place) and which of that a successful commit has covered.
///
/// Unchecked: `sequence`, `written`, `covered`, the commit counts and `random` are only read and
/// written under `lock`; the rest does not change.
internal final class DeferredTarget: FileSystemProvider, @unchecked Sendable {
    /// The file system that holds the files.
    internal let base: MemoryFileSystem
    /// How many commits in a hundred fail.
    internal let failureRate: Int
    /// Guards every `var`.
    private let lock = NSLock()
    /// Counts the changes.
    private var sequence = 0
    /// The change that last wrote each path.
    private var written: [String: Int] = [:]
    /// The last change a successful commit covers.
    private var covered = 0
    /// How many commits succeeded.
    private var commitsOK = 0
    /// How many commits failed.
    private var commitsFailed = 0
    /// Chooses the commits that fail.
    private var random: Random

    /// The base's scheme.
    internal var scheme: String { base.scheme }
    /// The base's capabilities.
    internal var capabilities: FileSystemCapabilities { base.capabilities }

    /// The commits so far, and the last change a successful one covers.
    internal var counts: CommitCounts {
        lock.withLock { CommitCounts(succeeded: commitsOK, failed: commitsFailed, covered: covered) }
    }

    /// A target over `base` whose commits fail `failureRate` times in a hundred, chosen by `seed`.
    internal init(_ base: MemoryFileSystem, seed: UInt64, failureRate: Int) {
        self.base = base
        random = Random(seed: seed)
        self.failureRate = failureRate
    }

    /// Notes a change of `url`.
    internal func wrote(_ url: URL) {
        lock.withLock {
            sequence += 1
            written[url.path] = sequence
        }
    }

    /// The change that last wrote `path`; nil when none did.
    internal func writtenAt(_ path: String) -> Int? {
        lock.withLock { written[path] }
    }

    /// The base's capabilities at `url`.
    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }

    /// The base's listing.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The base's listing.
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden, cancellation: cancellation)
    }

    /// The base's item.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The base's parent.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// Reads from the base.
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }

    /// Reads from the base.
    internal func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        try base.read(url, cancellation: cancellation)
    }

    /// Makes the folder in the base.
    internal func createDirectory(at url: URL) { base.createDirectory(at: url) }

    /// Writes to the base; the change is noted when the file is closed.
    internal func write(_ url: URL) throws -> any FileWriter {
        DeferredWriter(try base.write(url), owner: self, url: url)
    }

    /// Writes to the base; the change is noted when the file is closed.
    internal func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        DeferredWriter(try base.write(url, cancellation: cancellation), owner: self, url: url)
    }

    /// Appends in the base; the change is noted when the file is closed.
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        DeferredWriter(try base.append(to: url, at: offset, cancellation: cancellation), owner: self, url: url)
    }

    /// Removes from the base.
    internal func remove(_ url: URL) throws { try base.remove(url) }

    /// Renames in the base; a rename is a change that waits for a commit like any other.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
        lock.withLock {
            sequence += 1
            written[source.path] = nil
            written[destination.path] = sequence
        }
    }

    /// Copies in the base and notes the change.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
        wrote(destination)
    }

    /// Copies the metadata in the base.
    internal func copyMetadata(from source: URL, to destination: URL) throws {
        try base.copyMetadata(from: source, to: destination)
    }

    /// Commits in the base, and fails `failureRate` times in a hundred afterwards; a commit that
    /// succeeds covers every change so far.
    internal func commit(_ url: URL, cancellation: CancellationFlag) throws {
        let fails: Bool = lock.withLock {
            let fails = Int.random(in: 0..<100, using: &random) < failureRate
            if fails {
                commitsFailed += 1
            } else {
                commitsOK += 1
                covered = sequence
            }
            return fails
        }
        try base.commit(url, cancellation: cancellation)
        if fails {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    /// The base's quarantine.
    internal func quarantine(of url: URL) -> Data? { base.quarantine(of: url) }

    /// Sets the quarantine in the base.
    internal func setQuarantine(_ value: Data, of url: URL) throws { try base.setQuarantine(value, of: url) }

    /// The base's display path.
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }

    /// The base's location.
    internal func location(from text: String) -> URL? { base.location(from: text) }

    /// The base's volume.
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }

    deinit {
        // Nothing to release.
    }
}
