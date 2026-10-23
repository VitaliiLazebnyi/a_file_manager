import AFMKernel
import Foundation

/// A file system of a few made-up files, for what the memory file system cannot do: readers that
/// are slow to close, and files that do not end.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class Review2HookProvider: FileSystemProvider, @unchecked Sendable {
    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class Reader: FileReader, @unchecked Sendable {
        let owner: Review2HookProvider
        let data: Data?
        var position = 0

        init(_ owner: Review2HookProvider, data: Data?) {
            self.owner = owner
            self.data = data
        }

        func read(upToCount count: Int) -> Data? {
            guard let data else {
                return Data(repeating: 0x41, count: count)
            }
            guard position < data.count else {
                return nil
            }
            let block = data.subdata(in: position..<min(data.count, position + count))
            position += block.count
            return block
        }

        func seek(to offset: UInt64) { position = Int(offset) }

        func close() {
            owner.onClose()
            owner.lock.lock()
            owner.closed += 1
            owner.lock.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The scheme of its URLs, `hook`.
    internal let scheme = "hook"

    /// Nothing but reading.
    internal let capabilities: FileSystemCapabilities = []

    /// The sizes of files by path, for files whose contents are not given: they read as zeros.
    internal var sizes: [String: Int64] = [:]

    /// The paths that are special entries (devices, pipes).
    internal var special: Set<String> = []

    /// The contents of files by path.
    internal var contents: [String: Data] = [:]

    /// The paths of files that never end: they read as `A`s for ever.
    internal var endless: Set<String> = []

    /// Guards `closed`, which readers count on their own threads.
    private let lock = NSLock()

    /// How many readers were closed.
    private var closed = 0

    /// Called by `close()` of every reader, before it is counted; does nothing unless the test sets it.
    internal var onClose: () -> Void = {
        // Nothing to wait for unless the test says so.
    }

    /// How many readers were closed so far, from any thread.
    internal var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// No folder lists anything.
    internal func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }

    /// The folder above `directory`.
    internal func parent(of directory: URL) -> URL? { directory.deletingLastPathComponent() }

    /// Refused: nothing can be written.
    internal func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("x") }

    /// Refused: nothing can be written.
    internal func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("x") }

    /// Does nothing: the files are made up.
    internal func remove(_: URL) {
        // Nothing to remove.
    }

    /// Does nothing: the files are made up.
    internal func move(_: URL, to _: URL, replacing _: Bool) {
        // Nothing to move.
    }

    /// Does nothing: the files are made up.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) {
        // Nothing to copy.
    }

    /// The entry of `url`: special when its path is in `special`, its size from `sizes` or `contents`.
    internal func item(at url: URL) -> FileItem? {
        FileItem(
            url: url,
            name: url.lastPathComponent,
            kind: .init(isSpecial: special.contains(url.path)),
            stat: .init(size: sizes[url.path] ?? Int64(contents[url.path]?.count ?? 0))
        )
    }

    /// A reader of the file's contents, of zeros of its size, or of a stream that does not end.
    internal func read(_ url: URL) -> any FileReader {
        Reader(
            self,
            data: endless.contains(url.path) ? nil : contents[url.path] ?? Data(count: Int(sizes[url.path] ?? 0))
        )
    }

    deinit {
        // Nothing to release.
    }
}
