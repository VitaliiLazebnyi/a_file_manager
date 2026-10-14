public import AFMKernel
public import Foundation

/// Reading and writing files, with readers and writers that stall and can be interrupted.
extension MemoryFileSystem {
    /// A read or write was interrupted while it stalled, or after.
    public struct Interrupted: LocalizedError {
        /// Says that the transfer was interrupted.
        public var errorDescription: String? { "The transfer was interrupted." }
    }

    /// What one reader or writer waits on.
    ///
    /// `isInterrupted` is guarded by the lock of `stalls`.
    ///
    /// Unchecked: `isInterrupted` is guarded as said; the rest are constants.
    internal final class Stall: @unchecked Sendable {
        private let stalls: MemoryStalls
        private let onInterrupt: @Sendable () -> Void
        private var isInterrupted = false

        /// A stall in `stalls`; `onInterrupt` is called once, at the first interruption.
        internal init(_ stalls: MemoryStalls, onInterrupt: @escaping @Sendable () -> Void) {
            self.stalls = stalls
            self.onInterrupt = onInterrupt
        }

        /// Returns at once unless `stalling`, then when released; throws once interrupted, and from then on.
        internal func wait(stalling: Bool) throws {
            stalls.holdTransfer(stalling: stalling) { isInterrupted }
            if stalls.withLock(waking: false, { isInterrupted }) {
                throw Interrupted()
            }
        }

        /// Interrupts the transfer from any thread: a wait in it ends, and every later one throws.
        internal func interrupt() {
            let isFirst = stalls.withLock(waking: true) {
                defer { isInterrupted = true }
                return !isInterrupted
            }
            if isFirst {
                onInterrupt()
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Reads a file's bytes as they were when it was opened.
    ///
    /// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` touches
    /// only the stall, which is safe from any thread.
    private final class Reader: FileReader, @unchecked Sendable {
        private let data: Data
        private let stall: Stall
        private let stalls: Bool
        private var position = 0

        init(_ data: Data, stall: Stall, stalls: Bool) {
            self.data = data
            self.stall = stall
            self.stalls = stalls
        }

        func interrupt() { stall.interrupt() }

        func read(upToCount count: Int) throws -> Data? {
            try stall.wait(stalling: stalls)
            guard position < data.count else {
                return nil
            }
            let block = data.subdata(in: position..<min(position + count, data.count))
            position += block.count
            return block
        }

        func seek(to offset: UInt64) { position = min(Int(offset), data.count) }

        func close() {
            // Nothing is held open.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Collects what is written and stores it when closed.
    ///
    /// Unchecked: used by one thread at a time, as `FileWriter` allows; `interrupt` touches
    /// only the stall, which is safe from any thread.
    private final class Writer: FileWriter, @unchecked Sendable {
        private let store: (Data, FileAttributes) -> Void
        private let stall: Stall
        private let stalls: Bool
        private var data: Data

        init(_ data: Data, stall: Stall, stalls: Bool, store: @escaping (Data, FileAttributes) -> Void) {
            self.data = data
            self.stall = stall
            self.stalls = stalls
            self.store = store
        }

        func interrupt() { stall.interrupt() }

        func write(_ data: Data) throws {
            try stall.wait(stalling: stalls)
            self.data.append(data)
        }

        func close(attributes: FileAttributes) { store(data, attributes) }

        deinit {
            // Nothing to release.
        }
    }

    /// A reader of the file at `url`; its reads stall with `stallsReads`.
    ///
    /// Throws `NotFound` where there is no file.
    public func read(_ url: URL) throws -> any FileReader {
        let stalling = options.value.stallsReads
        return try synchronized {
            guard case .file(let contents)? = nodes[key(url)] else {
                throw NotFound(path: decoded(key(url)))
            }
            return Reader(contents.data, stall: makeStall(), stalls: stalling)
        }
    }

    /// A writer of a new, empty file at `url`, which holds what was written once the writer is closed; its writes stall
    /// with `stallsWrites`.
    ///
    /// Throws where the folder is missing or something has the name.
    public func write(_ url: URL) throws -> any FileWriter {
        let path = key(url)
        try synchronized {
            guard case .directory? = nodes[parentKey(path)] else {
                throw NotFound(path: decoded(parentKey(path)))
            }
            guard nodes[path] == nil else {
                throw FileSystemError.alreadyExists(decoded(path))
            }
            nodes[path] = .file(Contents(data: Data(), modified: Date(), permissions: 0o644))
        }
        return Writer(Data(), stall: makeStall(), stalls: options.value.stallsWrites) { [weak self] data, attributes in
            self?.store(data, at: path, modified: attributes.modified ?? Date(), permissions: attributes.permissions)
        }
    }

    /// Offered when `capabilities` holds `.append`: a writer that continues the file at `url` from `offset` (cut there
    /// first) or from its end (nil).
    ///
    /// What has been written shows when the writer is closed, with the date and permissions the file had unless others
    /// are given.
    public func append(to url: URL, at offset: Int64?, cancellation _: CancellationFlag) throws -> any FileWriter {
        guard capabilities(for: url).contains(.append) else {
            throw FileSystemError.notSupported("Continuing a file")
        }
        let path = key(url)
        let head = try synchronized {
            guard case .file(var contents)? = nodes[path] else {
                throw NotFound(path: decoded(path))
            }
            guard let offset else {
                return contents
            }
            guard offset >= 0, offset <= Int64(contents.data.count) else {
                throw FileSystemError.notSupported("Continuing \(decoded(path)) at \(offset)")
            }
            contents.data = contents.data.prefix(Int(offset))
            nodes[path] = .file(contents)
            return contents
        }
        let stalling = options.value.stallsWrites
        return Writer(head.data, stall: makeStall(), stalls: stalling) { [weak self] data, attributes in
            self?
                .store(
                    data,
                    at: path,
                    modified: attributes.modified ?? head.modified,
                    permissions: attributes.permissions ?? head.permissions
                )
        }
    }

    /// Puts the bytes of a closed writer at `path`.
    private func store(_ data: Data, at path: String, modified: Date, permissions: UInt16?) {
        synchronized {
            nodes[path] = .file(Contents(data: data, modified: modified, permissions: permissions ?? 0o644))
        }
    }

    /// A stall for a new reader or writer, which counts its interruption in `interruptions`.
    private func makeStall() -> Stall {
        Stall(stalls) { [weak self] in
            self?.synchronized { self?.records.interrupted += 1 }
        }
    }
}
