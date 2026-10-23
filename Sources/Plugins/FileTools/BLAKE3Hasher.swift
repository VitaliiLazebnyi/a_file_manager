import Foundation

/// BLAKE3, after the reference implementation of its authors: 1024-byte chunks hashed in
/// 64-byte blocks and joined in a binary tree.
///
/// Nothing is allocated per block: the working state lives in raw memory or on the stack. The
/// chunks of large inputs are hashed on all cores, each core taking a subtree of equal size, which
/// is correct because the chaining value of such a subtree does not depend on what is around it.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class BLAKE3Hasher: StreamHasher, @unchecked Sendable {
    /// A pointer handed to the threads of `subtree`; they work on separate parts of it.
    internal struct UncheckedPointer<Pointee>: @unchecked Sendable {
        /// The pointer.
        internal let pointer: Pointee

        /// Wraps `pointer`.
        internal init(_ pointer: Pointee) { self.pointer = pointer }
    }

    /// Where a block stands and what it is: what the compression function mixes in besides the words.
    internal struct Block {
        /// The number of the chunk the block belongs to; 0 for a parent.
        internal var counter: UInt64
        /// The bytes of the block that are input (64 for all but a chunk's last).
        internal var length: UInt32
        /// What the block is: `chunkStart`, `chunkEnd`, `parent`, `root`, combined.
        internal var flags: UInt32
    }

    /// The flag of a chunk's first block.
    internal static let chunkStart: UInt32 = 1
    /// The flag of a chunk's last block.
    internal static let chunkEnd: UInt32 = 2
    /// The flag of a parent's block.
    internal static let parent: UInt32 = 4
    /// The flag of the block whose output is the digest.
    internal static let root: UInt32 = 8
    /// The bytes of a chunk.
    internal static let chunkSize = 1_024

    /// The initial chaining value: the eight words of SHA-256's.
    ///
    /// Filled once, when first used, and only read afterwards.
    nonisolated(unsafe) internal static let initialValue: UnsafePointer<UInt32> = {
        let words: [UInt32] = [
            0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19
        ]
        let pointer = UnsafeMutablePointer<UInt32>.allocate(capacity: 8)
        pointer.initialize(from: words, count: 8)
        return UnsafePointer(pointer)
    }()

    /// The order in which each of the seven rounds takes the words of a block.
    ///
    /// Filled once, when first used, and only read afterwards.
    nonisolated(unsafe) internal static let schedule: UnsafePointer<UInt8> = {
        let permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
        var order = Array(0..<16)
        var all: [UInt8] = []
        for _ in 0..<7 {
            all += order.map { word in UInt8(word) }
            order = permutation.map { position in order[position] }
        }
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: all.count)
        pointer.initialize(from: all, count: all.count)
        return UnsafePointer(pointer)
    }()

    /// Inputs of at least this many chunks are split over the cores.
    internal static let parallelChunks = 16

    // MARK: The hasher

    /// The last (possibly full) chunk of the input so far.
    ///
    /// A full chunk is closed only when more input follows: the last one is the root's.
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: BLAKE3Hasher.chunkSize, alignment: 8)
    /// How many bytes `buffer` holds.
    private var bufferLength = 0
    /// How many chunks were closed so far.
    private var chunkCounter: UInt64 = 0
    /// The chaining values of finished subtrees (8 words each), the largest first.
    private let stack = UnsafeMutablePointer<UInt32>.allocate(capacity: 64 * 8)
    /// How many chaining values `stack` holds.
    private var stackCount = 0

    /// The chaining value at `index` of the stack.
    private func stackEntry(_ index: Int) -> UnsafeMutableBufferPointer<UInt32> {
        UnsafeMutableBufferPointer(start: stack + index * 8, count: 8)
    }

    /// A finished subtree of `2^level` chunks joins the tree: for every pair of equal subtrees
    /// that is complete now (one per trailing zero bit of the chunk count) a parent takes their place.
    private func add(_ value: UnsafeMutableBufferPointer<UInt32>, level: Int) {
        var total = (chunkCounter + (1 << UInt64(level))) >> UInt64(level)
        chunkCounter += 1 << UInt64(level)
        while total & 1 == 0, stackCount > 0 {
            stackCount -= 1
            Self.join(
                UnsafeBufferPointer(stackEntry(stackCount)),
                UnsafeBufferPointer(value),
                isRoot: false,
                into: value
            )
            total >>= 1
        }
        let entry = stackEntry(stackCount)
        for index in 0..<8 {
            entry[index] = value[index]
        }
        stackCount += 1
    }

    /// Hashes the full chunk in `buffer` and adds it to the tree.
    private func closeBufferedChunk() {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { value in
            Self.chunk(buffer, length: Self.chunkSize, counter: chunkCounter, isRoot: false, into: value)
            add(value, level: 0)
        }
        bufferLength = 0
    }

    /// Adds the next block: whole chunks followed by more input go into the tree (large runs of them on all
    /// cores), the rest waits in `buffer`.
    internal func update(_ data: Data) {
        data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard let base = input.baseAddress, !input.isEmpty else {
                return
            }
            var offset = topUpBuffer(base, count: input.count)
            guard offset < input.count else {
                return
            }
            offset += addWholeChunks(base + offset, count: input.count - offset)
            buffer.copyMemory(from: base + offset, byteCount: input.count - offset)
            bufferLength = input.count - offset
        }
    }

    /// Puts the start of the input into the chunk held back, if there is one, and closes that chunk when more
    /// input follows it; returns how many bytes it took.
    private func topUpBuffer(_ base: UnsafeRawPointer, count: Int) -> Int {
        let size = Self.chunkSize
        // More input follows a full chunk that was held back.
        if bufferLength == size {
            closeBufferedChunk()
        }
        guard bufferLength > 0 else {
            return 0
        }
        let take = min(size - bufferLength, count)
        (buffer + bufferLength).copyMemory(from: base, byteCount: take)
        bufferLength += take
        if take < count {
            closeBufferedChunk()
        }
        return take
    }

    /// Adds the whole chunks of the input that are followed by at least one more byte, as subtrees as large as
    /// the position in the tree allows; returns how many bytes they were.
    private func addWholeChunks(_ base: UnsafeRawPointer, count: Int) -> Int {
        let size = Self.chunkSize
        var chunks = (count - 1) / size
        var offset = 0
        while chunks > 0 {
            var level = 0
            while 1 << (level + 1) <= chunks, chunkCounter.isMultiple(of: 1 << UInt64(level + 1)) {
                level += 1
            }
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { value in
                Self.subtree(base + offset, chunks: 1 << level, counter: chunkCounter, into: value)
                add(value, level: level)
            }
            offset += size << level
            chunks -= 1 << level
        }
        return offset
    }

    /// The 32 bytes of the digest: the last chunk joined with the finished subtrees from the smallest up.
    internal func finish() -> [UInt8] {
        var words = [UInt32](repeating: 0, count: 16)
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { value in
            Self.chunk(buffer, length: bufferLength, counter: chunkCounter, isRoot: stackCount == 0, into: value)
            // The last chunk is joined with the finished subtrees from the smallest up.
            for index in stride(from: stackCount - 1, through: 0, by: -1) {
                Self.join(
                    UnsafeBufferPointer(stackEntry(index)),
                    UnsafeBufferPointer(value),
                    isRoot: index == 0,
                    into: value
                )
            }
            for index in 0..<8 {
                words[index] = value[index]
            }
        }
        return words.prefix(8)
            .flatMap { word in (0..<4).map { byte in UInt8(truncatingIfNeeded: word >> (8 * UInt32(byte))) } }
    }

    deinit {
        buffer.deallocate()
        stack.deallocate()
    }
}
