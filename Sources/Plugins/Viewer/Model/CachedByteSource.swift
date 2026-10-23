import AFMKernel
import Foundation

/// Keeps the blocks read last, so scrolling back and forth and drawing the same rows again do
/// not go to the file system each time.
///
/// Safe to use from several threads.
///
/// Long sequential reads (indexing, searching) would only push the shown blocks out, so they go
/// past the cache; except for a file small enough to be kept whole (`wholeFileLimit`, for
/// sources where a read is expensive, like a server): the read is then done in one request and
/// every block of it is kept, so laying the text out again does not fetch the file again. A
/// bigger file of such a source is kept on disk with `spillsToDisk` (`DiskBlockCache`): long
/// reads fetch only the blocks the disk does not have, and the rest comes from the disk.
///
/// `blocks` and `order` are guarded by `lock`; everything else is immutable or safe itself.
internal final class CachedByteSource: ByteSource, @unchecked Sendable {
    /// How a cache keeps blocks: their size and number, and what it keeps whole or on disk.
    internal struct Policy: Sendable {
        /// What the viewer uses for a file on a local disk: 48 blocks of 128 KB in memory, nothing
        /// kept whole, nothing on disk.
        internal static let standard = Self(
            blockSize: 128 * 1_024,
            capacity: 48,
            wholeFileLimit: 0,
            spillsToDisk: false,
            diskLimit: 1 << 30
        )

        /// The size of a block (at least 1).
        internal var blockSize: Int
        /// How many blocks are kept in memory (at least 2).
        internal var capacity: Int
        /// A source no longer than this, and than the blocks in memory hold, is kept whole once
        /// read; 0 keeps no source whole.
        internal var wholeFileLimit: Int64
        /// Whether a source that is not kept whole keeps its blocks on disk as well.
        internal var spillsToDisk: Bool
        /// The most the source keeps on disk.
        internal var diskLimit: Int64
    }

    /// The source the blocks come from.
    internal let base: any ByteSource
    /// The size of a block.
    internal let blockSize: Int
    private let capacity: Int
    private let keepsWholeFile: Bool
    private let spill: DiskBlockCache?
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    /// Block numbers, least recently used first.
    private var order: [Int64] = []

    /// The length of the base.
    internal var length: Int64 { base.length }

    /// Bytes of the file kept on disk now (zero without `spillsToDisk`).
    internal var diskBytes: Int64 { spill?.storedBytes ?? 0 }
    /// Whether the file on disk is open now.
    internal var diskCacheIsOpen: Bool { spill?.isOpen ?? false }

    /// A cache in front of `base` that keeps blocks as `policy` says.
    internal init(_ base: any ByteSource, policy: Policy) {
        self.base = base
        let size = max(1, policy.blockSize)
        let kept = max(2, policy.capacity)
        blockSize = size
        capacity = kept
        keepsWholeFile = base.length <= policy.wholeFileLimit && base.length <= Int64(size) * Int64(kept)
        spill =
            policy.spillsToDisk && !keepsWholeFile && base.length > 0
            ? DiskBlockCache(blockSize: size, length: base.length, limit: policy.diskLimit) : nil
    }

    /// The bytes from `offset` on, at most `count`, from the blocks kept or from the base.
    internal func read(at offset: Int64, count: Int) throws -> Data {
        try read(at: offset, count: count, flag: nil)
    }

    /// `read(at:count:)`, interrupted (throwing) once `cancellation` is set.
    internal func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data {
        try read(at: offset, count: count, flag: cancellation)
    }

    /// Closes the base and forgets the blocks kept on disk; those in memory stay.
    internal func close() {
        base.close()
        spill?.discard()
    }

    private func read(at offset: Int64, count: Int, flag: CancellationFlag?) throws -> Data {
        try autoreleasepool { try readInPool(at: offset, count: count, flag: flag) }
    }

    private func readInPool(at offset: Int64, count: Int, flag: CancellationFlag?) throws -> Data {
        let lower = max(0, min(offset, length))
        let upper = min(length, lower + Int64(max(0, count)))
        guard upper > lower else {
            return Data()
        }
        try flag?.throwIfCancelled()
        // Four blocks or more is a scan, not a look at what is shown.
        if upper - lower >= Int64(blockSize) * 4 {
            if keepsWholeFile {
                return try readAndKeep(lower, upper, flag)
            }
            if let spill {
                return try readThroughDisk(lower, upper, spill, flag)
            }
            return try fetch(lower, Int(upper - lower), flag)
        }
        var result = Data(capacity: Int(upper - lower))
        var block = lower / Int64(blockSize)
        while block * Int64(blockSize) < upper {
            let data = try self.block(block, flag)
            append(data, ofBlock: block, within: lower..<upper, to: &result)
            if data.count < blockSize { break }
            block += 1
        }
        return result
    }

    /// Appends the part of block `number` (whose bytes are `data`) that lies in `range`.
    private func append(_ data: Data, ofBlock number: Int64, within range: Range<Int64>, to result: inout Data) {
        let start = number * Int64(blockSize)
        let first = Int(max(range.lowerBound, start) - start)
        let end = Int(min(range.upperBound, start + Int64(data.count)) - start)
        if end > first { result.append(data.subdata(in: first..<end)) }
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
                append(data, ofBlock: number, within: lower..<upper, to: &result)
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
            // The whole file fits in the capacity: nothing is pushed out.
            blocks[number] = piece
            order.append(number)
        }
        lock.unlock()
        let from = Int(lower - alignedLower)
        return from < data.count ? data.subdata(in: from..<min(data.count, Int(upper - alignedLower))) : Data()
    }

    /// A long read of a file that is too big for memory: the blocks the disk has come from the
    /// disk, each run of the others in one request to the base, and every block is stored.
    private func readThroughDisk(_ lower: Int64, _ upper: Int64, _ spill: DiskBlockCache, _ flag: CancellationFlag?)
        throws -> Data
    {
        let size = Int64(blockSize)
        let first = lower / size
        let last = (upper - 1) / size
        var result = Data(capacity: Int(upper - lower))
        var number = first
        while number <= last {
            try flag?.throwIfCancelled()
            if let data = spill.read(number) {
                append(data, ofBlock: number, within: lower..<upper, to: &result)
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
                append(part, ofBlock: piece, within: lower..<upper, to: &result)
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
        guard data.count == blockSize || number * Int64(blockSize) + Int64(data.count) == length else {
            return data
        }
        lock.lock()
        if blocks[number] == nil {
            blocks[number] = data
            order.append(number)
            if order.count > capacity { blocks[order.removeFirst()] = nil }
        }
        lock.unlock()
        return data
    }

    deinit {
        // Nothing to release: the disk cache gives its room back when it is freed.
    }
}
