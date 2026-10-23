import Foundation

/// The blocks of a file on a slow file system, kept on disk: a temporary file with holes (one
/// per source), so reading the whole file again, as laying a big text out anew does, is a
/// read of the local disk and not of the server.
///
/// The file has no name once it is open, so nothing is left behind whatever happens to the program.
/// All the sources together keep at most what their `DiskBudget` allows (2 GB) and one source at
/// most 1 GB; a source that finds the room used up goes on without caching more. Safe to use from
/// several threads: the state of a cache is guarded by `lock`; the shared budget guards itself; the
/// rest is immutable.
internal final class DiskBlockCache: @unchecked Sendable {
    /// The size of a block; only the last block of the file is shorter.
    internal let blockSize: Int
    private let length: Int64
    /// The most this one cache holds.
    private let limit: Int64
    /// The room on disk this cache shares with the others.
    private let budget: DiskBudget
    /// Opens the file the blocks are kept in: a descriptor open for reading and writing, or a
    /// negative number when there is none.
    private let openFile: @Sendable () -> Int32
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var present: [UInt64]
    private var held: Int64 = 0
    private var failed = false

    /// Bytes this cache holds.
    internal var storedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// Whether the file the blocks are kept in is open (from the first block stored to `discard`).
    internal var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    /// A cache of at most `limit` bytes of a file of `length` bytes, in an unnamed temporary file,
    /// sharing the viewer's budget with the other caches.
    internal convenience init(blockSize: Int, length: Int64, limit: Int64) {
        self.init(blockSize: blockSize, length: length, limit: limit, budget: .shared, openFile: Self.openUnnamedFile)
    }

    /// A cache that shares `budget` with others and keeps its blocks in the file `openFile`
    /// opens when the first block is stored.
    internal init(
        blockSize: Int,
        length: Int64,
        limit: Int64,
        budget: DiskBudget,
        openFile: @escaping @Sendable () -> Int32
    ) {
        self.blockSize = blockSize
        self.length = length
        self.limit = limit
        self.budget = budget
        self.openFile = openFile
        present = Array(repeating: 0, count: Int((length / Int64(blockSize) + 64) / 64))
    }

    /// A new temporary file that is gone from the directory at once: the system removes the
    /// data when the file is closed, whatever happens to the program.
    internal static func openUnnamedFile() -> Int32 {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "afm-viewer-p\(getpid())-blocks-\(UUID().uuidString)"
            )
            .path
        let opened = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if opened >= 0 { unlink(path) }
        return opened
    }

    /// Whether block number `block` is stored.
    internal func contains(_ block: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPresent(block)
    }

    /// The block as it was stored; nil when it was not, or the disk fails to give it back.
    internal func read(_ block: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, isPresent(block) else {
            return nil
        }
        let wanted = size(of: block)
        var data = Data(count: wanted)
        let got = data.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, wanted, off_t(block * Int64(blockSize)))
        }
        guard got == wanted else {
            // The block is gone (a failing disk): its room goes back to the budget.
            present[Int(block / 64)] &= ~(1 << UInt64(block % 64))
            held -= Int64(wanted)
            budget.release(Int64(wanted))
            return nil
        }
        return data
    }

    /// Keeps a whole block (or the short last one of the file), if there is room for it.
    internal func store(_ block: Int64, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, data.count == size(of: block), !data.isEmpty, !isPresent(block),
            held + Int64(data.count) <= limit,
            budget.reserve(Int64(data.count))
        else { return }
        if descriptor < 0 {
            let opened = openFile()
            guard opened >= 0 else {
                failed = true
                budget.release(Int64(data.count))
                return
            }
            descriptor = opened
        }
        let wrote = data.withUnsafeBytes { buffer in
            pwrite(descriptor, buffer.baseAddress, data.count, off_t(block * Int64(blockSize)))
        }
        guard wrote == data.count else {
            // A full disk: no more is tried.
            failed = true
            budget.release(Int64(data.count))
            return
        }
        present[Int(block / 64)] |= 1 << UInt64(block % 64)
        held += Int64(data.count)
    }

    /// Forgets everything and gives the disk space back; storing again starts a new file.
    internal func discard() {
        lock.lock()
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        for index in present.indices { present[index] = 0 }
        let given = held
        held = 0
        failed = false
        lock.unlock()
        if given > 0 { budget.release(given) }
    }

    private func size(of block: Int64) -> Int { Int(min(Int64(blockSize), length - block * Int64(blockSize))) }

    private func isPresent(_ block: Int64) -> Bool {
        let word = Int(block / 64)
        return block >= 0 && word < present.count && present[word] & (1 << UInt64(block % 64)) != 0
    }

    deinit { discard() }
}
