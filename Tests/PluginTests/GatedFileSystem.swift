import AFMKernel
import Foundation
import TestSupport

/// A file system over memory whose reads wait until they are let go.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class GatedFileSystem: FileSystemProvider, @unchecked Sendable {
    /// The file system that holds the files.
    internal let base = MemoryFileSystem(scheme: "gated")
    /// The scheme of `base`, so that its locations are this file system's.
    internal var scheme: String { base.scheme }
    /// Writing only, as a server offers it.
    internal var capabilities: FileSystemCapabilities { [.write] }
    /// Signalled when a held read has its reader in hand and starts to wait.
    internal let entered = DispatchSemaphore(value: 0)
    /// Signalled by the test to let a held read go on.
    internal let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var waits = false
    private var count = 0

    /// How many reads were opened.
    internal var reads: Int { lock.withLock { count } }

    /// Makes the next read wait at `gate` after it has opened its reader.
    internal func holdNextRead() { lock.withLock { waits = true } }

    /// The entries of `directory` in `base`.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }

    /// The item at `url` in `base`.
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }

    /// The folder above `directory` in `base`.
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }

    /// A reader of the contents as they are now; a held read hands it out only after the gate opens.
    internal func read(_ url: URL) throws -> any FileReader {
        // The contents as they are now; handed out only after the gate opens.
        let reader = try base.read(url)
        let held: Bool = lock.withLock {
            count += 1
            defer { waits = false }
            return waits
        }
        if held {
            entered.signal()
            gate.wait()
        }
        return reader
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

    /// Copies an item inside `base`.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }

    deinit {
        // Nothing to release.
    }
}
