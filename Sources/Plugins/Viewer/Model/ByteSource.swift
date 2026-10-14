import AFMKernel
import Foundation

/// What the viewer reports about the file it is reading.
enum ViewerError: LocalizedError, Equatable {
    /// A read inside the length the file had when it was opened came back short: the file was
    /// truncated or replaced while it was shown, and what is shown is incomplete.
    case fileChanged
    /// A pipe, a device or a socket: reading it may never end.
    case notAFile(String)
    /// A source of unknown size that does not end (a device behind a link, a stream).
    case endless(String)
    /// Too many reads that cannot be ended are still waiting on the file systems: nothing more is started.
    case busy

    var errorDescription: String? {
        switch self {
        case .fileChanged:
            return "The file changed while it was being read (it became shorter); what is shown may be incomplete."

        case .notAFile(let name):
            return "\(name) is not a regular file (a pipe, device or socket), and cannot be shown."

        case .endless(let name): return "\(name) does not end, and cannot be shown."
        case .busy: return "Too many reads are still waiting for a volume that does not answer; this file was not read."
        }
    }
}

/// Where things that wait for a file system are done that nobody is waiting for: closing the
/// readers of a file that is no longer shown (an SFTP or FTP close is a request to the server
/// and waits for the answer, up to the session's time-out), deleting copies. Never call these
/// from a queue that must not wait, and hand work here from the main thread.
enum ViewerCleanup {
    private static let queue = DispatchQueue(label: "viewer.cleanup", qos: .userInitiated, attributes: .concurrent)

    static func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Closes the source off the calling thread.
    static func close(_ source: ByteSource?) {
        guard let source else { return }
        queue.async { source.close() }
    }

    static func close(_ readers: [FileReader]) {
        guard !readers.isEmpty else { return }
        queue.async { readers.forEach { $0.close() } }
    }

    /// Returns once everything handed over so far has been done (for tests).
    static func drain() {
        queue.sync(flags: .barrier) {}
    }
}

/// Random access to the bytes of what is being viewed. The viewer never holds a file whole: it
/// asks for the pieces it shows (spec 10 › Window model: the text modes stream the file).
/// `read` blocks and is safe to call from several threads at once; never call it on the main
/// thread.
protocol ByteSource: AnyObject {
    var length: Int64 { get }
    /// The bytes from `offset` on, at most `count`; fewer only at the end of the file.
    func read(at offset: Int64, count: Int) throws -> Data
    /// `read(at:count:)`, ended early, by throwing, once `cancellation` is set: a read that is
    /// blocked in a server's answer is interrupted, so whoever drops the work does not wait
    /// for it.
    func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data
    /// Lets go of whatever the source holds open. Reading afterwards opens it again.
    func close()
}

extension ByteSource {
    func close() {}

    func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data {
        try cancellation.throwIfCancelled()
        return try read(at: offset, count: count)
    }

    /// `read(at:count:)`, interruptible when there is a flag.
    func read(at offset: Int64, count: Int, interruptedBy cancellation: CancellationFlag?) throws -> Data {
        guard let cancellation else { return try read(at: offset, count: count) }
        return try read(at: offset, count: count, cancellation: cancellation)
    }

    /// The bytes of `range`, clipped to the file.
    func read(_ range: Range<Int64>) throws -> Data {
        try read(range, cancellation: nil)
    }

    func read(_ range: Range<Int64>, cancellation: CancellationFlag?) throws -> Data {
        let lower = max(0, min(range.lowerBound, length))
        let upper = max(lower, min(range.upperBound, length))
        return upper > lower ? try read(at: lower, count: Int(upper - lower), interruptedBy: cancellation) : Data()
    }
}

extension CancellationFlag {
    /// What a read that was ended by its flag throws; whoever set the flag does not look at it.
    func throwIfCancelled() throws {
        if isCancelled { throw CocoaError(.userCancelled) }
    }

    /// Runs `body` with `reader` interrupted should the flag be set meanwhile.
    func whileReading<T>(_ reader: FileReader, _ body: () throws -> T) rethrows -> T {
        let token = interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        return try body()
    }
}

/// A flag that is set when any of its parents is, for work that has a stop of its own and also
/// ends with the document or the pane it belongs to. Keep the value for as long as the work
/// runs; letting go of it unhooks the flag from its parents.
final class LinkedCancellation {
    let flag = CancellationFlag()
    private let tokens: [AnyObject]

    init(_ parents: CancellationFlag...) {
        let flag = flag
        tokens = parents.map { $0.onCancel { [weak flag] in flag?.cancel() } }
    }
}

/// Bytes that are in memory already: a text handed to the viewer, a small file.
final class DataByteSource: ByteSource {
    private let data: Data

    init(_ data: Data) {
        // A slice keeps the indices of what it was cut from; a copy starts at zero.
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    var length: Int64 { Int64(data.count) }

    func read(at offset: Int64, count: Int) -> Data {
        let lower = Int(max(0, min(offset, length)))
        let upper = min(data.count, lower + max(0, count))
        return data.subdata(in: lower..<upper)
    }
}

/// A file on any file system, read through its provider with `seek` and `read`, so the viewer
/// works wherever a panel can show files (archives, servers). Several threads read at once,
/// each through a reader of its own; idle readers are kept for the next request.
final class ProviderByteSource: ByteSource {
    let url: URL
    let length: Int64
    private let provider: FileSystemProvider
    private let lock = NSLock()
    private var idle: [FileReader] = []
    /// How often the source was closed.
    private var closes = 0
    private let idleLimit = ProcessInfo.processInfo.activeProcessorCount

    init(url: URL, provider: FileSystemProvider, length: Int64) {
        self.url = url
        self.provider = provider
        self.length = length
    }

    /// Opens `url` for viewing. The size comes from the directory entry; a file system that
    /// cannot tell it (or tells zero) is measured by reading the file once. A file on the local
    /// disk that the entry only knows as a link is measured by asking for the size of what it
    /// points to; pipes, devices and sockets are refused. Blocks; ends early (throwing) once
    /// `cancellation` is set.
    static func open(_ url: URL, fileSystems: FileSystemRegistry, cancellation: CancellationFlag = CancellationFlag())
        throws -> ByteSource
    {
        let provider = try fileSystems.provider(for: url)
        let entry = provider.item(at: url, cancellation: cancellation)
        if let entry, entry.isSpecial { throw ViewerError.notAFile(url.lastPathComponent) }
        // A link to a file whose file system already knows the target's size: no need to ask for it again.
        if let entry, entry.isSymlink, !entry.isDirectory, let size = entry.linkTargetSize, size > 0 {
            return ProviderByteSource(url: url, provider: provider, length: size)
        }
        if let entry, entry.size > 0, !entry.isDirectory {
            return ProviderByteSource(url: url, provider: provider, length: entry.size)
        }
        try cancellation.throwIfCancelled()
        if url.isFileURL, entry?.isDirectory != true {
            // The entry of a link says nothing of its target's size (it is not the link's); the
            // target is asked, so a link to a big file is not read to its end to count it.
            var target = stat()
            if stat(url.path, &target) == 0 {
                switch target.st_mode & S_IFMT {
                case S_IFREG:
                    return target.st_size > 0
                        ? ProviderByteSource(url: url, provider: provider, length: Int64(target.st_size))
                        : DataByteSource(Data())

                case S_IFDIR:
                    break

                default:
                    throw ViewerError.notAFile(url.lastPathComponent)
                }
            }
        }
        let reader = try provider.read(url, cancellation: cancellation)
        defer { reader.close() }
        // Small content of unknown size is simply kept; anything larger is only counted.
        var kept = Data()
        var total: Int64 = 0
        try cancellation.whileReading(reader) {
            while let block = try autoreleasepool(invoking: { try reader.read(upToCount: 1 << 20) }), !block.isEmpty {
                try cancellation.throwIfCancelled()
                total += Int64(block.count)
                // A stream that never ends (a device) is no file.
                guard total <= measuringLimit else { throw ViewerError.endless(url.lastPathComponent) }
                if total <= measuredKeepLimit { kept.append(block) } else { kept = Data() }
            }
        }
        try cancellation.throwIfCancelled()
        return total <= measuredKeepLimit
            ? DataByteSource(kept) : ProviderByteSource(url: url, provider: provider, length: total)
    }

    /// The most that is read to find the size of a file the file system cannot give.
    static let measuringLimit: Int64 = 1 << 40

    private static let measuredKeepLimit: Int64 = 16 << 20

    func read(at offset: Int64, count: Int) throws -> Data {
        try read(at: offset, count: count, flag: nil)
    }

    func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data {
        try read(at: offset, count: count, flag: cancellation)
    }

    private func read(at offset: Int64, count: Int, flag: CancellationFlag?) throws -> Data {
        guard count > 0, offset < length else { return Data() }
        try flag?.throwIfCancelled()
        // The buffers a read leaves behind are freed at once: the threads that read live long.
        return try autoreleasepool {
            let (reader, epoch) = try checkOut(flag)
            var data = Data()
            do {
                try Self.reading(reader, flag) {
                    try reader.seek(to: UInt64(max(0, offset)))
                    let wanted = Int(min(Int64(count), length - offset))
                    while data.count < wanted, let block = try reader.read(upToCount: wanted - data.count),
                        !block.isEmpty
                    {
                        data.append(block)
                        try flag?.throwIfCancelled()
                    }
                }
            } catch {
                reader.close()
                throw error
            }
            // A reader the flag interrupted (or may still be about to) is of no use again.
            if flag?.isCancelled == true { reader.close() } else { checkIn(reader, epoch: epoch) }
            return data
        }
    }

    private static func reading(_ reader: FileReader, _ flag: CancellationFlag?, _ body: () throws -> Void) throws {
        if let flag { try flag.whileReading(reader, body) } else { try body() }
    }

    /// A reader and the number of `close`s there were when it was taken.
    private func checkOut(_ flag: CancellationFlag?) throws -> (FileReader, Int) {
        lock.lock()
        let reader = idle.popLast()
        let epoch = closes
        lock.unlock()
        if let reader { return (reader, epoch) }
        return (try flag.map { try provider.read(url, cancellation: $0) } ?? provider.read(url), epoch)
    }

    private func checkIn(_ reader: FileReader, epoch: Int) {
        lock.lock()
        // A reader that was in use when the source was closed is not kept: closing means it all.
        let keep = idle.count < idleLimit && epoch == closes
        if keep { idle.append(reader) }
        lock.unlock()
        if !keep { reader.close() }
    }

    /// Lets go of the idle readers, and of the ones in use as they come back. The readers are
    /// closed on a background queue: closing one may wait for the server, and `close` is called
    /// where nothing may wait (the main thread, as the file shown changes).
    func close() {
        lock.lock()
        let readers = idle
        idle = []
        closes += 1
        lock.unlock()
        ViewerCleanup.close(readers)
    }

    deinit { ViewerCleanup.close(idle) }
}

/// The blocks of a file on a slow file system, kept on disk: a temporary file with holes (one
/// per source), so reading the whole file again, as laying a big text out anew does, is a
/// read of the local disk and not of the server. The file has no name once it is open, so
/// nothing is left behind whatever happens to the program. All the sources together keep at
/// most `totalLimit` bytes and one source at most 1 GB; a source that finds the room used up
/// goes on without caching more.
/// Safe to use from several threads.
final class DiskBlockCache {
    /// The most all caches together hold.
    static let totalLimit: Int64 = 2 << 30
    private static let budget = NSLock()
    private static var held: Int64 = 0

    /// Bytes all caches hold now.
    static var totalHeld: Int64 {
        budget.lock()
        defer { budget.unlock() }
        return held
    }

    private static func reserve(_ bytes: Int64) -> Bool {
        budget.lock()
        defer { budget.unlock() }
        guard held + bytes <= totalLimit else { return false }
        held += bytes
        return true
    }

    private static func release(_ bytes: Int64) {
        budget.lock()
        held -= bytes
        budget.unlock()
    }

    let blockSize: Int
    private let length: Int64
    /// The most this one cache holds.
    private let limit: Int64
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var present: [UInt64]
    private var held: Int64 = 0
    private var failed = false

    init(blockSize: Int, length: Int64, limit: Int64 = 1 << 30) {
        self.blockSize = blockSize
        self.length = length
        self.limit = limit
        present = Array(repeating: 0, count: Int((length / Int64(blockSize) + 64) / 64))
    }

    /// Bytes this cache holds.
    var storedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    private func size(of block: Int64) -> Int { Int(min(Int64(blockSize), length - block * Int64(blockSize))) }

    func contains(_ block: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPresent(block)
    }

    private func isPresent(_ block: Int64) -> Bool {
        let word = Int(block / 64)
        return block >= 0 && word < present.count && present[word] & (1 << UInt64(block % 64)) != 0
    }

    /// The block as it was stored; nil when it was not, or the disk fails to give it back.
    func read(_ block: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, isPresent(block) else { return nil }
        let wanted = size(of: block)
        var data = Data(count: wanted)
        let got = data.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, wanted, off_t(block * Int64(blockSize)))
        }
        guard got == wanted else {
            // The block is gone (a failing disk): its room goes back to the budget.
            present[Int(block / 64)] &= ~(1 << UInt64(block % 64))
            held -= Int64(wanted)
            Self.release(Int64(wanted))
            return nil
        }
        return data
    }

    /// Keeps a whole block (or the short last one of the file), if there is room for it.
    func store(_ block: Int64, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, data.count == size(of: block), data.count > 0, !isPresent(block),
            held + Int64(data.count) <= limit,
            Self.reserve(Int64(data.count))
        else { return }
        if descriptor < 0 {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                "afm-viewer-p\(getpid())-blocks-\(UUID().uuidString)"
            ).path
            let opened = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard opened >= 0 else {
                failed = true
                Self.release(Int64(data.count))
                return
            }
            // Gone from the directory at once: the system removes the data when the file is closed.
            unlink(path)
            descriptor = opened
        }
        let wrote = data.withUnsafeBytes {
            pwrite(descriptor, $0.baseAddress, data.count, off_t(block * Int64(blockSize)))
        }
        guard wrote == data.count else {
            // A full disk: no more is tried.
            failed = true
            Self.release(Int64(data.count))
            return
        }
        present[Int(block / 64)] |= 1 << UInt64(block % 64)
        held += Int64(data.count)
    }

    /// Forgets everything and gives the disk space back; storing again starts a new file.
    func discard() {
        lock.lock()
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        for index in present.indices { present[index] = 0 }
        let given = held
        held = 0
        failed = false
        lock.unlock()
        if given > 0 { Self.release(given) }
    }

    deinit { discard() }
}

/// Keeps the blocks read last, so scrolling back and forth and drawing the same rows again do
/// not go to the file system each time. Safe to use from several threads.
///
/// Long sequential reads (indexing, searching) would only push the shown blocks out, so they go
/// past the cache; except for a file small enough to be kept whole (`wholeFileLimit`, for
/// sources where a read is expensive, like a server): the read is then done in one request and
/// every block of it is kept, so laying the text out again does not fetch the file again. A
/// bigger file of such a source is kept on disk with `spillsToDisk` (`DiskBlockCache`): long
/// reads fetch only the blocks the disk does not have, and the rest comes from the disk.
final class CachedByteSource: ByteSource {
    let base: ByteSource
    let blockSize: Int
    private let capacity: Int
    private let keepsWholeFile: Bool
    private let spill: DiskBlockCache?
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    /// Block numbers, least recently used first.
    private var order: [Int64] = []

    init(
        _ base: ByteSource, blockSize: Int = 128 * 1_024, capacity: Int = 48, wholeFileLimit: Int64 = 0,
        spillsToDisk: Bool = false,
        diskLimit: Int64 = 1 << 30
    ) {
        self.base = base
        let blockSize = max(1, blockSize)
        let capacity = max(2, capacity)
        self.blockSize = blockSize
        self.capacity = capacity
        keepsWholeFile = base.length <= wholeFileLimit && base.length <= Int64(blockSize) * Int64(capacity)
        spill =
            spillsToDisk && !keepsWholeFile && base.length > 0
            ? DiskBlockCache(blockSize: blockSize, length: base.length, limit: diskLimit) : nil
    }

    var length: Int64 { base.length }

    /// Bytes of the file kept on disk now (zero without `spillsToDisk`).
    var diskBytes: Int64 { spill?.storedBytes ?? 0 }
    /// Whether the file on disk is open now.
    var diskCacheIsOpen: Bool { spill?.isOpen ?? false }

    func read(at offset: Int64, count: Int) throws -> Data {
        try read(at: offset, count: count, flag: nil)
    }

    func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data {
        try read(at: offset, count: count, flag: cancellation)
    }

    private func read(at offset: Int64, count: Int, flag: CancellationFlag?) throws -> Data {
        try autoreleasepool { try readInPool(at: offset, count: count, flag: flag) }
    }

    private func readInPool(at offset: Int64, count: Int, flag: CancellationFlag?) throws -> Data {
        let lower = max(0, min(offset, length))
        let upper = min(length, lower + Int64(max(0, count)))
        guard upper > lower else { return Data() }
        try flag?.throwIfCancelled()
        // Four blocks or more is a scan, not a look at what is shown.
        if upper - lower >= Int64(blockSize) * 4 {
            if keepsWholeFile { return try readAndKeep(lower, upper, flag) }
            if spill != nil { return try readThroughDisk(lower, upper, flag) }
            return try fetch(lower, Int(upper - lower), flag)
        }
        var result = Data(capacity: Int(upper - lower))
        var block = lower / Int64(blockSize)
        while block * Int64(blockSize) < upper {
            let data = try self.block(block, flag)
            let start = block * Int64(blockSize)
            let from = Int(max(lower, start) - start)
            let to = Int(min(upper, start + Int64(data.count)) - start)
            if to > from { result.append(data.subdata(in: from..<to)) }
            if data.count < blockSize { break }
            block += 1
        }
        return result
    }

    private func fetch(_ offset: Int64, _ count: Int, _ flag: CancellationFlag?) throws -> Data {
        try flag.map { try base.read(at: offset, count: count, cancellation: $0) }
            ?? base.read(at: offset, count: count)
    }

    /// A long read in one request to the base, unless all of it is cached; its blocks are kept.
    private func readAndKeep(_ lower: Int64, _ upper: Int64, _ flag: CancellationFlag?) throws -> Data {
        let size = Int64(blockSize)
        let first = lower / size
        let last = (upper - 1) / size
        lock.lock()
        let cached = (first...last).allSatisfy { blocks[$0] != nil }
        lock.unlock()
        if cached {
            var result = Data(capacity: Int(upper - lower))
            for number in first...last {
                let data = try block(number, flag)
                let start = number * size
                let from = Int(max(lower, start) - start)
                let to = Int(min(upper, start + Int64(data.count)) - start)
                if to > from { result.append(data.subdata(in: from..<to)) }
                if data.count < blockSize { break }
            }
            return result
        }
        let alignedLower = first * size
        let alignedUpper = min(length, (last + 1) * size)
        let data = try fetch(alignedLower, Int(alignedUpper - alignedLower), flag)
        lock.lock()
        for number in first...last {
            let from = Int(number * size - alignedLower)
            guard from < data.count else { break }
            let piece = data.subdata(in: from..<min(data.count, from + blockSize))
            // A short block in the middle would end later reads early.
            guard piece.count == blockSize || number * size + Int64(piece.count) == length, blocks[number] == nil else {
                continue
            }
            blocks[number] = piece
            order.append(number)
            if order.count > capacity { blocks[order.removeFirst()] = nil }
        }
        lock.unlock()
        let from = Int(lower - alignedLower)
        return from < data.count ? data.subdata(in: from..<min(data.count, Int(upper - alignedLower))) : Data()
    }

    /// A long read of a file that is too big for memory: the blocks the disk has come from the
    /// disk, each run of the others in one request to the base, and every block is stored.
    private func readThroughDisk(_ lower: Int64, _ upper: Int64, _ flag: CancellationFlag?) throws -> Data {
        guard let spill else { return try fetch(lower, Int(upper - lower), flag) }
        let size = Int64(blockSize)
        let first = lower / size
        let last = (upper - 1) / size
        var result = Data(capacity: Int(upper - lower))
        /// Appends the part of block `number` (whose bytes are `data`) that was asked for.
        func take(_ number: Int64, _ data: Data) {
            let start = number * size
            let from = Int(max(lower, start) - start)
            let to = Int(min(upper, start + Int64(data.count)) - start)
            if to > from { result.append(data.subdata(in: from..<to)) }
        }
        var number = first
        while number <= last {
            try flag?.throwIfCancelled()
            if let data = spill.read(number) {
                take(number, data)
                number += 1
                continue
            }
            var end = number
            while end < last, !spill.contains(end + 1) { end += 1 }
            let runStart = number * size
            let runEnd = min(length, (end + 1) * size)
            let data = try fetch(runStart, Int(runEnd - runStart), flag)
            for piece in number...end {
                let from = Int(piece * size - runStart)
                guard from < data.count else { break }
                let part = data.subdata(in: from..<min(data.count, from + blockSize))
                spill.store(piece, part)
                take(piece, part)
            }
            // A read that came back short ends the file early, as it does for any source.
            if Int64(data.count) < runEnd - runStart { break }
            number = end + 1
        }
        return result
    }

    private func block(_ number: Int64, _ flag: CancellationFlag?) throws -> Data {
        lock.lock()
        if let data = blocks[number] {
            if order.last != number {
                order.removeAll { $0 == number }
                order.append(number)
            }
            lock.unlock()
            return data
        }
        lock.unlock()
        let data = try spill?.read(number) ?? fetch(number * Int64(blockSize), blockSize, flag)
        spill?.store(number, data)
        // Only a whole block, or the short last one of the file, is kept: a block cut short by a
        // read that failed in the middle would end later reads early until it is pushed out.
        guard data.count == blockSize || number * Int64(blockSize) + Int64(data.count) == length else { return data }
        lock.lock()
        if blocks[number] == nil {
            blocks[number] = data
            order.append(number)
            if order.count > capacity { blocks[order.removeFirst()] = nil }
        }
        lock.unlock()
        return data
    }

    func close() {
        base.close()
        spill?.discard()
    }
}
