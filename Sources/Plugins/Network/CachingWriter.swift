import AFMKernel
import Foundation

/// Passes everything on to another writer and keeps the cached listing of its directory
/// right: the entry gets its size and date when the file is finished, and the directory is
/// forgotten when the file is not (a failed or abandoned upload leaves an unknown state).
///
/// Used by one thread at a time, as `FileWriter` allows; `interrupt` only passes the call on to
/// the writer underneath, which is safe from any thread.
internal final class CachingWriter: FileWriter, @unchecked Sendable {
    /// The session's writer, which does the work.
    private let writer: any FileWriter
    /// The listings kept right.
    private let cache: EntryCache
    /// The location of the folder the file is in.
    private let directory: URL
    /// The file's name in `directory`.
    private let name: String
    /// The size of the file so far, what was there before an append included.
    private var written: Int64
    /// Whether `close` was called; a writer let go without it leaves the folder unknown.
    private var isDone = false

    /// A writer that passes on to `writer` the file `name` in `directory`, which already holds `written` bytes.
    internal init(_ writer: any FileWriter, cache: EntryCache, directory: URL, name: String, written: Int64) {
        self.written = written
        self.writer = writer
        self.cache = cache
        self.directory = directory
        self.name = name
    }

    /// Writes `data` at the end of the file; a failure makes the folder unknown.
    internal func write(_ data: Data) throws {
        do {
            try writer.write(data)
            written += Int64(data.count)
        } catch {
            cache.forget(directory)
            throw error
        }
    }

    /// Ends a write that waits, from any thread.
    internal func interrupt() { writer.interrupt() }

    /// Finishes the file and enters its size, date and permissions into the listing.
    internal func close(attributes: FileAttributes) throws {
        isDone = true
        do {
            try writer.close(attributes: attributes)
        } catch {
            cache.forget(directory)
            throw error
        }
        let (size, modified, permissions) = (written, attributes.modified, attributes.permissions)
        cache.update(name, in: directory) { entry in
            entry.size = size
            entry.modified = modified ?? Date()
            if let permissions { entry.permissions = permissions & 0o7777 }
        }
    }

    deinit {
        if !isDone { cache.forget(directory) }
    }
}
