import Foundation

/// The compression function, the chunks and the parents of the tree.
extension BLAKE3Hasher {
    // MARK: The compression function

    /// `value` rotated right by `count` bits (1…31).
    @inline(__always)
    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value &>> count) | (value &<< (32 &- count))
    }

    /// The quarter-round G on the four words of `state` at `places`, mixing in the message words `first`
    /// and `second`.
    @inline(__always)
    private static func mix(
        _ state: UnsafeMutableBufferPointer<UInt32>,
        _ places: SIMD4<Int>,
        _ first: UInt32,
        _ second: UInt32
    ) {
        let (left, right, third, fourth) = (places[0], places[1], places[2], places[3])
        state[left] = state[left] &+ state[right] &+ first
        state[fourth] = rotr(state[fourth] ^ state[left], 16)
        state[third] = state[third] &+ state[fourth]
        state[right] = rotr(state[right] ^ state[third], 12)
        state[left] = state[left] &+ state[right] &+ second
        state[fourth] = rotr(state[fourth] ^ state[left], 8)
        state[third] = state[third] &+ state[fourth]
        state[right] = rotr(state[right] ^ state[third], 7)
    }

    /// Compresses one block of 16 `words` under the chaining value `value` (8 words) into `state`, 16 words:
    /// the first eight are the new chaining value, all sixteen the output of a root.
    private static func compress(
        _ value: UnsafeBufferPointer<UInt32>,
        _ words: UnsafeBufferPointer<UInt32>,
        _ block: Block,
        into state: UnsafeMutableBufferPointer<UInt32>
    ) {
        for index in 0..<8 {
            state[index] = value[index]
        }
        for index in 0..<4 {
            state[8 + index] = initialValue[index]
        }
        state[12] = UInt32(truncatingIfNeeded: block.counter)
        state[13] = UInt32(truncatingIfNeeded: block.counter >> 32)
        state[14] = block.length
        state[15] = block.flags
        let order = schedule
        for round in 0..<7 {
            let start = round * 16
            func word(_ position: Int) -> UInt32 { words[Int(order[start + position])] }
            mix(state, SIMD4(0, 4, 8, 12), word(0), word(1))
            mix(state, SIMD4(1, 5, 9, 13), word(2), word(3))
            mix(state, SIMD4(2, 6, 10, 14), word(4), word(5))
            mix(state, SIMD4(3, 7, 11, 15), word(6), word(7))
            mix(state, SIMD4(0, 5, 10, 15), word(8), word(9))
            mix(state, SIMD4(1, 6, 11, 12), word(10), word(11))
            mix(state, SIMD4(2, 7, 8, 13), word(12), word(13))
            mix(state, SIMD4(3, 4, 9, 14), word(14), word(15))
        }
        for index in 0..<8 {
            state[index] ^= state[index + 8]
            state[index + 8] ^= value[index]
        }
    }

    // MARK: Chunks and parents

    /// The chaining value (8 words) of a chunk of `length` bytes (1…1024).
    ///
    /// With `isRoot` the chunk is the whole input and the eight words are the start of the digest.
    internal static func chunk(
        _ input: UnsafeRawPointer,
        length: Int,
        counter: UInt64,
        isRoot: Bool,
        into out: UnsafeMutableBufferPointer<UInt32>
    ) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 40) { scratch in
            let value = UnsafeMutableBufferPointer(rebasing: scratch[0..<8])
            let words = UnsafeMutableBufferPointer(rebasing: scratch[8..<24])
            let state = UnsafeMutableBufferPointer(rebasing: scratch[24..<40])
            for index in 0..<8 {
                value[index] = initialValue[index]
            }
            let blocks = max(1, (length + 63) / 64)
            for block in 0..<blocks {
                let offset = block * 64
                let blockLength = min(64, length - offset)
                load(input + offset, length: blockLength, into: words)
                var flags: UInt32 = block == 0 ? chunkStart : 0
                if block == blocks - 1 {
                    flags |= chunkEnd | (isRoot ? root : 0)
                }
                compress(
                    UnsafeBufferPointer(value),
                    UnsafeBufferPointer(words),
                    Block(counter: counter, length: UInt32(blockLength), flags: flags),
                    into: state
                )
                for index in 0..<8 {
                    value[index] = state[index]
                }
            }
            for index in 0..<8 {
                out[index] = value[index]
            }
        }
    }

    /// The 16 words of a block of `length` bytes (0…64), padded with zeros.
    @inline(__always)
    private static func load(_ input: UnsafeRawPointer, length: Int, into words: UnsafeMutableBufferPointer<UInt32>) {
        if length == 64 {
            for index in 0..<16 {
                words[index] = UInt32(littleEndian: input.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
            }
        } else {
            for index in 0..<16 {
                words[index] = 0
            }
            UnsafeMutableRawBufferPointer(words).copyMemory(from: UnsafeRawBufferPointer(start: input, count: length))
        }
    }

    /// The chaining value (8 words) of the parent of two subtrees; with `isRoot` the start of the digest.
    /// `out` may be one of the two.
    internal static func join(
        _ left: UnsafeBufferPointer<UInt32>,
        _ right: UnsafeBufferPointer<UInt32>,
        isRoot: Bool,
        into out: UnsafeMutableBufferPointer<UInt32>
    ) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 32) { scratch in
            let words = UnsafeMutableBufferPointer(rebasing: scratch[0..<16])
            let state = UnsafeMutableBufferPointer(rebasing: scratch[16..<32])
            for index in 0..<8 {
                words[index] = left[index]
                words[index + 8] = right[index]
            }
            compress(
                UnsafeBufferPointer(start: initialValue, count: 8),
                UnsafeBufferPointer(words),
                Block(counter: 0, length: 64, flags: parent | (isRoot ? root : 0)),
                into: state
            )
            for index in 0..<8 {
                out[index] = state[index]
            }
        }
    }

    /// The chaining value of `chunks` (a power of two) whole chunks, on this thread.
    private static func serialSubtree(
        _ input: UnsafeRawPointer,
        chunks: Int,
        counter: UInt64,
        into out: UnsafeMutableBufferPointer<UInt32>
    ) {
        if chunks == 1 {
            chunk(input, length: chunkSize, counter: counter, isRoot: false, into: out)
            return
        }
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 16) { pair in
            let left = UnsafeMutableBufferPointer(rebasing: pair[0..<8])
            let right = UnsafeMutableBufferPointer(rebasing: pair[8..<16])
            let half = chunks / 2
            serialSubtree(input, chunks: half, counter: counter, into: left)
            serialSubtree(input + half * chunkSize, chunks: half, counter: counter + UInt64(half), into: right)
            join(UnsafeBufferPointer(left), UnsafeBufferPointer(right), isRoot: false, into: out)
        }
    }

    /// Like `serialSubtree`, but a large subtree is cut into equal parts that the cores hash
    /// side by side; their chaining values are joined here.
    internal static func subtree(
        _ input: UnsafeRawPointer,
        chunks: Int,
        counter: UInt64,
        into out: UnsafeMutableBufferPointer<UInt32>
    ) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var parts = 1
        while parts * 2 <= cores * 2, parts * 2 <= chunks / 4 {
            parts *= 2
        }
        guard chunks >= parallelChunks, parts > 1 else {
            serialSubtree(input, chunks: chunks, counter: counter, into: out)
            return
        }
        let size = chunks / parts
        let values = UnsafeMutablePointer<UInt32>.allocate(capacity: parts * 8)
        defer { values.deallocate() }
        func entry(_ index: Int) -> UnsafeMutableBufferPointer<UInt32> {
            UnsafeMutableBufferPointer(start: values + index * 8, count: 8)
        }
        let source = UncheckedPointer(input)
        let target = UncheckedPointer(values)
        DispatchQueue.concurrentPerform(iterations: parts) { index in
            serialSubtree(
                source.pointer + index * size * chunkSize,
                chunks: size,
                counter: counter + UInt64(index * size),
                into: UnsafeMutableBufferPointer(start: target.pointer + index * 8, count: 8)
            )
        }
        var count = parts
        while count > 1 {
            for index in 0..<(count / 2) {
                join(
                    UnsafeBufferPointer(entry(index * 2)),
                    UnsafeBufferPointer(entry(index * 2 + 1)),
                    isRoot: false,
                    into: entry(index)
                )
            }
            count /= 2
        }
        for index in 0..<8 {
            out[index] = values[index]
        }
    }
}
