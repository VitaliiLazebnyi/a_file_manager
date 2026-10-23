import Foundation

/// SHA-3 (FIPS 202): the Keccak sponge with 1600 bits of state.
///
/// CryptoKit has it from macOS 26 on (and not SHA3-224 at all); this is the version for the others.
/// It works on raw memory with wrapping arithmetic: nothing in the permutation is checked or
/// allocated.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class SHA3Hasher: StreamHasher, @unchecked Sendable {
    /// The constants of the 24 rounds' last step (iota).
    ///
    /// Filled once, when first used, and only read afterwards.
    nonisolated(unsafe) private static let roundConstants = table([
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8009, 0x0000_0000_0000_008A, 0x0000_0000_0000_0088,
        0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080,
        0x0000_0000_0000_800A, 0x8000_0000_8000_000A, 0x8000_0000_8000_8081, 0x8000_0000_0000_8080,
        0x0000_0000_8000_0001, 0x8000_0000_8000_8008
    ])

    /// The lanes of rho and pi in the order of their one cycle of 24, starting after lane 1: each takes
    /// the one before it, rotated by its offset in `rotations`.
    ///
    /// Filled once, when first used, and only read afterwards.
    nonisolated(unsafe) private static let cycle = table([
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
    ])

    /// The rotation of each lane of `cycle`, in bits.
    ///
    /// Filled once, when first used, and only read afterwards.
    nonisolated(unsafe) private static let rotations = table([
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44
    ])

    /// The 25 lanes of the state.
    private let state = UnsafeMutablePointer<UInt64>.allocate(capacity: 25)
    /// The bytes absorbed per block: 200 less twice the digest length.
    private let rate: Int
    /// The bytes of the digest.
    private let digestLength: Int
    /// Input that does not fill a block of `rate` bytes yet.
    private let pending: UnsafeMutableRawPointer
    /// How many bytes `pending` holds.
    private var pendingCount = 0

    /// A hasher at the start of its input, for a digest of `digestLength` bytes (28, 32, 48 or 64).
    internal init(digestLength: Int) {
        self.digestLength = digestLength
        rate = 200 - 2 * digestLength
        state.initialize(repeating: 0, count: 25)
        pending = .allocate(byteCount: 200, alignment: 8)
    }

    /// `values` in memory of their own, which lives as long as the program.
    private static func table(_ values: [UInt64]) -> UnsafeMutablePointer<UInt64> {
        let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: values.count)
        pointer.initialize(from: values, count: values.count)
        return pointer
    }

    /// `value` rotated left by `count` bits (1…63).
    @inline(__always)
    private static func rotl(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value &<< count) | (value &>> (64 &- count))
    }

    /// Keccak-f[1600]: the 24 rounds over the state.
    private static func permute(_ lanes: UnsafeMutablePointer<UInt64>) {
        let constants = roundConstants
        for round in 0..<24 {
            theta(lanes)
            rhoAndPi(lanes)
            chi(lanes)
            lanes[0] ^= constants[round]
        }
    }

    /// Theta: every lane takes in the parities of the two columns next to it.
    @inline(__always)
    private static func theta(_ lanes: UnsafeMutablePointer<UInt64>) {
        let parity0 = lanes[0] ^ lanes[5] ^ lanes[10] ^ lanes[15] ^ lanes[20]
        let parity1 = lanes[1] ^ lanes[6] ^ lanes[11] ^ lanes[16] ^ lanes[21]
        let parity2 = lanes[2] ^ lanes[7] ^ lanes[12] ^ lanes[17] ^ lanes[22]
        let parity3 = lanes[3] ^ lanes[8] ^ lanes[13] ^ lanes[18] ^ lanes[23]
        let parity4 = lanes[4] ^ lanes[9] ^ lanes[14] ^ lanes[19] ^ lanes[24]
        let effect0 = parity4 ^ rotl(parity1, 1)
        let effect1 = parity0 ^ rotl(parity2, 1)
        let effect2 = parity1 ^ rotl(parity3, 1)
        let effect3 = parity2 ^ rotl(parity4, 1)
        let effect4 = parity3 ^ rotl(parity0, 1)
        for row in stride(from: 0, to: 25, by: 5) {
            lanes[row] ^= effect0
            lanes[row + 1] ^= effect1
            lanes[row + 2] ^= effect2
            lanes[row + 3] ^= effect3
            lanes[row + 4] ^= effect4
        }
    }

    /// Rho and pi: every lane moves to its place, rotated, along one cycle of 24 lanes.
    @inline(__always)
    private static func rhoAndPi(_ lanes: UnsafeMutablePointer<UInt64>) {
        let (order, offsets) = (cycle, rotations)
        var carried = lanes[1]
        for step in 0..<24 {
            let lane = Int(order[step])
            let next = lanes[lane]
            lanes[lane] = rotl(carried, offsets[step])
            carried = next
        }
    }

    /// Chi: every lane takes in the two lanes after it in its row.
    @inline(__always)
    private static func chi(_ lanes: UnsafeMutablePointer<UInt64>) {
        for row in stride(from: 0, to: 25, by: 5) {
            let (lane0, lane1, lane2, lane3, lane4) = (
                lanes[row], lanes[row + 1], lanes[row + 2], lanes[row + 3], lanes[row + 4]
            )
            lanes[row] = lane0 ^ (~lane1 & lane2)
            lanes[row + 1] = lane1 ^ (~lane2 & lane3)
            lanes[row + 2] = lane2 ^ (~lane3 & lane4)
            lanes[row + 3] = lane3 ^ (~lane4 & lane0)
            lanes[row + 4] = lane4 ^ (~lane0 & lane1)
        }
    }

    /// XORs one block of `rate` bytes into the state and permutes it.
    private func absorb(_ block: UnsafeRawPointer) {
        for index in 0..<(rate / 8) {
            state[index] ^= UInt64(littleEndian: block.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))
        }
        Self.permute(state)
    }

    /// Adds the next block: whole blocks of `rate` bytes are absorbed, the rest waits in `pending`.
    internal func update(_ data: Data) {
        data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard !input.isEmpty, let base = input.baseAddress else {
                return
            }
            var offset = 0
            if pendingCount > 0 {
                let take = min(rate - pendingCount, input.count)
                pending.advanced(by: pendingCount).copyMemory(from: base, byteCount: take)
                pendingCount += take
                offset = take
                guard pendingCount == rate else {
                    return
                }
                absorb(pending)
                pendingCount = 0
            }
            while input.count - offset >= rate {
                absorb(base + offset)
                offset += rate
            }
            pending.copyMemory(from: base + offset, byteCount: input.count - offset)
            pendingCount = input.count - offset
        }
    }

    /// Pads and absorbs what is pending, and returns the first `digestLength` bytes of the state.
    internal func finish() -> [UInt8] {
        _ = (pending + pendingCount).initializeMemory(as: UInt8.self, repeating: 0, count: rate - pendingCount)
        pending.storeBytes(
            of: pending.load(fromByteOffset: pendingCount, as: UInt8.self) ^ 0x06,
            toByteOffset: pendingCount,
            as: UInt8.self
        )
        pending.storeBytes(
            of: pending.load(fromByteOffset: rate - 1, as: UInt8.self) ^ 0x80,
            toByteOffset: rate - 1,
            as: UInt8.self
        )
        absorb(pending)
        return Array(UnsafeRawBufferPointer(start: state, count: digestLength))
    }

    deinit {
        state.deallocate()
        pending.deallocate()
    }
}
