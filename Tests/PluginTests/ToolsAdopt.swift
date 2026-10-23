import AFMKernel
import Foundation
import TestSupport

/// What the suites of the tools' adoption share: a file system that tells when an operation is under way, the
/// outcome of a background thread, and two names that read alike.
internal enum ToolsAdopt {
    /// A file system that forwards everything to a `MemoryFileSystem` and says when a listing, a
    /// read or a write has been opened, so that a test cancels while the operation is under way
    /// and not before it.
    internal final class ProbingFileSystem: FileSystemProvider {
        /// The file system everything goes to.
        internal let memory: MemoryFileSystem
        /// Signalled when a listing has begun.
        internal let listing = DispatchSemaphore(value: 0)
        /// Signalled when a read has been opened.
        internal let reading = DispatchSemaphore(value: 0)
        /// Signalled when a write has been opened.
        internal let writing = DispatchSemaphore(value: 0)

        /// The scheme of the file system in memory.
        internal var scheme: String { memory.scheme }
        /// The capabilities of the file system in memory.
        internal var capabilities: FileSystemCapabilities { memory.capabilities }

        /// A probe of `memory`.
        internal init(_ memory: MemoryFileSystem) { self.memory = memory }

        /// The capabilities of the file system in memory at `url`.
        internal func capabilities(for url: URL) -> FileSystemCapabilities { memory.capabilities(for: url) }

        /// Lists the folder, without a signal.
        internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
            try memory.list(directory, showHidden: showHidden)
        }

        /// Signals `listing`, and lists the folder.
        internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
            listing.signal()
            return try memory.list(directory, showHidden: showHidden, cancellation: cancellation)
        }

        /// Signals `listing`, and lists the folder in batches.
        internal func list(
            _ directory: URL,
            showHidden: Bool,
            cancellation: CancellationFlag,
            receive: ([FileItem]) -> Bool
        ) throws {
            listing.signal()
            try memory.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
        }

        /// The item at `url`.
        internal func item(at url: URL) -> FileItem? { memory.item(at: url) }

        /// The item at `url`, unless cancelled.
        internal func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
            memory.item(at: url, cancellation: cancellation)
        }

        /// The folder above `directory`.
        internal func parent(of directory: URL) -> URL? { memory.parent(of: directory) }

        /// Opens a read, without a signal.
        internal func read(_ url: URL) throws -> any FileReader { try memory.read(url) }

        /// Opens a read, and signals `reading`.
        internal func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
            let reader = try memory.read(url, cancellation: cancellation)
            reading.signal()
            return reader
        }

        /// Creates the folder.
        internal func createDirectory(at url: URL) { memory.createDirectory(at: url) }

        /// Opens a write, without a signal.
        internal func write(_ url: URL) throws -> any FileWriter { try memory.write(url) }

        /// Opens a write, and signals `writing`.
        internal func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
            let writer = try memory.write(url, cancellation: cancellation)
            writing.signal()
            return writer
        }

        /// Removes the item.
        internal func remove(_ url: URL) throws { try memory.remove(url) }

        /// Moves the item.
        internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
            try memory.move(source, to: destination, replacing: replacing)
        }

        /// Copies the file inside the file system in memory.
        internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
            try memory.copy(source, to: destination, progress: progress)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// What a background thread produced.
    ///
    /// Unchecked: the value is guarded by `lock`.
    internal final class Outcome<Value>: @unchecked Sendable {
        /// Guards `stored`.
        private let lock = NSLock()
        /// The value (under `lock`).
        private var stored: Value?

        /// The value; nil until the thread set it.
        internal var value: Value? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Two names that read the same and are two files on a server or a disk from elsewhere: NFC.
    internal static let composed = "caf\u{e9}.txt"
    /// The same name in NFD.
    internal static let decomposed = "cafe\u{301}.txt"

    /// Runs `work` on its own thread; the semaphore is signalled when it ends.
    internal static func background(_ work: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }
        .start()
        return done
    }

    /// Sets the flag from a thread of its own, as a Cancel button would.
    internal static func cancelFromThread(_ flag: CancellationFlag) {
        _ = background { flag.cancel() }.wait(timeout: .now() + Wait.ceiling)
    }

    /// Whether two names are the same bytes, not only the same to Swift.
    internal static func isExactly(_ name: String, _ other: String) -> Bool { name.utf8.elementsEqual(other.utf8) }
}
