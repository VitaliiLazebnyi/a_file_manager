import CommonCrypto
import CryptoKit
import Foundation
import zlib

/// A checksum that is fed a file block by block.
///
/// One hasher belongs to one thread at a time, and may go from one thread to another between
/// blocks.
internal protocol StreamHasher: AnyObject, Sendable {
    func update(_ data: Data)
    /// The digest; the hasher is used up afterwards.
    func finish() -> [UInt8]
}

/// The checksum methods of "Create checksum files" (spec 08 › Methods).
///
/// The raw values are the numbers of the spec's `Lastmd5` setting.
internal enum ChecksumMethod: Int, CaseIterable, Codable {
    case crc32 = 0
    case md5, sha1, sha256, sha512, sha224, sha384, sha3_256, sha3_512, sha3_224, sha3_384, blake3

    /// The order of the dialog.
    internal static let dialogOrder = allCases.sorted { $0.dialogPosition < $1.dialogPosition }

    /// The place in the dialog.
    internal var dialogPosition: Int {
        switch self {
        case .crc32:
            return 0

        case .md5:
            return 1

        case .sha1:
            return 2

        case .blake3:
            return 3

        case .sha224:
            return 4

        case .sha256:
            return 5

        case .sha384:
            return 6

        case .sha512:
            return 7

        case .sha3_224:
            return 8

        case .sha3_256:
            return 9

        case .sha3_384:
            return 10

        case .sha3_512:
            return 11
        }
    }

    internal var title: String {
        switch self {
        case .crc32:
            return "CRC32 (SFV)"

        case .md5:
            return "MD5"

        case .sha1:
            return "SHA1"

        case .sha256:
            return "SHA256"

        case .sha512:
            return "SHA512"

        case .sha224:
            return "SHA224"

        case .sha384:
            return "SHA384"

        case .sha3_256:
            return "SHA3_256"

        case .sha3_512:
            return "SHA3_512"

        case .sha3_224:
            return "SHA3_224"

        case .sha3_384:
            return "SHA3_384"

        case .blake3:
            return "BLAKE3"
        }
    }

    /// The name in the title of the Verify window: `MD5`, `SHA2_256` (spec 08 › Verify window).
    internal var reportName: String {
        switch self {
        case .crc32:
            return "CRC32"

        case .sha224, .sha256, .sha384, .sha512:
            return "SHA2_" + title.dropFirst(3)

        default:
            return title
        }
    }

    /// The extension of the checksum file.
    ///
    /// The spec records `.sfv`, `.md5`, `.sha`, `.sha256` and `.bk3`; the others follow the same
    /// pattern.
    internal var fileExtension: String {
        switch self {
        case .crc32:
            return "sfv"

        case .md5:
            return "md5"

        case .sha1:
            return "sha"

        case .blake3:
            return "bk3"

        default:
            return title.lowercased()
        }
    }

    /// The method as OpenSSL-style lines name it: `SHA256(name)= …`, `SHA3-256(name)= …`.
    internal var tagName: String {
        title.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: "CRC32 (SFV)", with: "CRC32")
    }

    internal var digestLength: Int {
        switch self {
        case .crc32:
            return 4

        case .md5:
            return 16

        case .sha1:
            return 20

        case .sha224, .sha3_224:
            return 28

        case .sha256, .sha3_256, .blake3:
            return 32

        case .sha384, .sha3_384:
            return 48

        case .sha512, .sha3_512:
            return 64
        }
    }

    /// The methods a digest of this many hex digits can come from (spec 08 › Hash-length
    /// disambiguation), the SHA-2 family first.
    internal static func candidates(hexDigits: Int) -> [Self] {
        [.crc32, .md5, .sha1, .sha224, .sha256, .sha384, .sha512, .sha3_224, .sha3_256, .sha3_384, .sha3_512, .blake3]
            .filter { $0.digestLength * 2 == hexDigits }
    }

    internal func makeHasher() -> any StreamHasher {
        switch self {
        case .crc32:
            return CRC32Hasher()

        case .md5:
            return CryptoHasher<Insecure.MD5>()

        case .sha1:
            return CryptoHasher<Insecure.SHA1>()

        case .sha256:
            return CryptoHasher<SHA256>()

        case .sha384:
            return CryptoHasher<SHA384>()

        case .sha512:
            return CryptoHasher<SHA512>()

        case .sha224:
            return SHA224Hasher()

        // The own implementation on every system: CryptoKit has SHA-3 only from macOS 26 on, and
        // is about a sixth faster there (845 against 705 MB/s for SHA3-256 on one core), less
        // than the disks the files come from deliver.
        case .sha3_224, .sha3_256, .sha3_384, .sha3_512:
            return SHA3Hasher(digestLength: digestLength)

        case .blake3:
            return BLAKE3Hasher()
        }
    }
}

extension Sequence where Element == UInt8 {
    internal var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// CRC32 with the system's zlib, which uses the processor's CRC instructions.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class CRC32Hasher: StreamHasher, @unchecked Sendable {
    internal private(set) var value: UInt = zlib.crc32(0, nil, 0)

    internal func update(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard !buffer.isEmpty, var pointer = buffer.bindMemory(to: Bytef.self).baseAddress else {
                return
            }
            var left = buffer.count
            // zlib counts in 32 bits.
            while left > 0 {
                let step = min(left, 1 << 30)
                value = zlib.crc32(value, pointer, uInt(step))
                pointer += step
                left -= step
            }
        }
    }

    internal var checksum: UInt32 { UInt32(truncatingIfNeeded: value) }

    internal func finish() -> [UInt8] {
        withUnsafeBytes(of: checksum.bigEndian, Array.init)
    }
}

/// MD5 and the SHA-1/SHA-2 hashes of CryptoKit.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class CryptoHasher<Function: HashFunction>: StreamHasher, @unchecked Sendable {
    private var function = Function()

    internal func update(_ data: Data) { function.update(data: data) }
    internal func finish() -> [UInt8] { Array(function.finalize()) }
}

/// SHA-224, which CryptoKit leaves out.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class SHA224Hasher: StreamHasher, @unchecked Sendable {
    private var context = CC_SHA256_CTX()

    internal init() { CC_SHA224_Init(&context) }

    internal func update(_ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let step = min(buffer.count - offset, 1 << 30)
                CC_SHA224_Update(&context, buffer.baseAddress?.advanced(by: offset), CC_LONG(step))
                offset += step
            }
        }
    }

    internal func finish() -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        CC_SHA224_Final(&digest, &context)
        return digest
    }
}

/// SHA-3 (FIPS 202): the Keccak sponge with 1600 bits of state.
///
/// CryptoKit has it from macOS 26 on (and not SHA3-224 at all); this is the version for the others.
/// It works on raw memory with wrapping arithmetic: nothing in the permutation is checked or
/// allocated.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class SHA3Hasher: StreamHasher, @unchecked Sendable {
    private let state = UnsafeMutablePointer<UInt64>.allocate(capacity: 25)
    private let rate: Int
    private let digestLength: Int
    /// Input that does not fill a block of `rate` bytes yet.
    private let pending: UnsafeMutableRawPointer
    private var pendingCount = 0

    internal init(digestLength: Int) {
        self.digestLength = digestLength
        rate = 200 - 2 * digestLength
        state.initialize(repeating: 0, count: 25)
        pending = .allocate(byteCount: 200, alignment: 8)
    }

    deinit {
        state.deallocate()
        pending.deallocate()
    }

    /// Filled once, when first used, and only read afterwards.
    nonisolated(unsafe) private static let roundConstants: UnsafeMutablePointer<UInt64> = {
        let constants: [UInt64] = [
            0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
            0x0000_0000_0000_808B, 0x0000_0000_8000_0001,
            0x8000_0000_8000_8081, 0x8000_0000_0000_8009, 0x0000_0000_0000_008A, 0x0000_0000_0000_0088,
            0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
            0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
            0x8000_0000_0000_8002, 0x8000_0000_0000_0080,
            0x0000_0000_0000_800A, 0x8000_0000_8000_000A, 0x8000_0000_8000_8081, 0x8000_0000_0000_8080,
            0x0000_0000_8000_0001, 0x8000_0000_8000_8008
        ]
        let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: constants.count)
        pointer.initialize(from: constants, count: constants.count)
        return pointer
    }()

    /// XORs one block of `rate` bytes into the state and permutes it.
    private func absorb(_ block: UnsafeRawPointer) {
        for index in 0..<(rate / 8) {
            state[index] ^= UInt64(littleEndian: block.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))
        }
        Self.permute(state)
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ n: UInt64) -> UInt64 { (x &<< n) | (x &>> (64 &- n)) }

    private static func permute(_ a: UnsafeMutablePointer<UInt64>) {
        let constants = roundConstants
        for round in 0..<24 {
            let c0 = a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20]
            let c1 = a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21]
            let c2 = a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22]
            let c3 = a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23]
            let c4 = a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24]
            let d0 = c4 ^ rotl(c1, 1)
            let d1 = c0 ^ rotl(c2, 1)
            let d2 = c1 ^ rotl(c3, 1)
            let d3 = c2 ^ rotl(c4, 1)
            let d4 = c3 ^ rotl(c0, 1)
            for row in stride(from: 0, to: 25, by: 5) {
                a[row] ^= d0
                a[row + 1] ^= d1
                a[row + 2] ^= d2
                a[row + 3] ^= d3
                a[row + 4] ^= d4
            }
            // Rho and pi: every lane moves to its place, rotated, along one cycle of 24 lanes.
            var carried = a[1]
            var next: UInt64
            next = a[10]
            a[10] = rotl(carried, 1)
            carried = next
            next = a[7]
            a[7] = rotl(carried, 3)
            carried = next
            next = a[11]
            a[11] = rotl(carried, 6)
            carried = next
            next = a[17]
            a[17] = rotl(carried, 10)
            carried = next
            next = a[18]
            a[18] = rotl(carried, 15)
            carried = next
            next = a[3]
            a[3] = rotl(carried, 21)
            carried = next
            next = a[5]
            a[5] = rotl(carried, 28)
            carried = next
            next = a[16]
            a[16] = rotl(carried, 36)
            carried = next
            next = a[8]
            a[8] = rotl(carried, 45)
            carried = next
            next = a[21]
            a[21] = rotl(carried, 55)
            carried = next
            next = a[24]
            a[24] = rotl(carried, 2)
            carried = next
            next = a[4]
            a[4] = rotl(carried, 14)
            carried = next
            next = a[15]
            a[15] = rotl(carried, 27)
            carried = next
            next = a[23]
            a[23] = rotl(carried, 41)
            carried = next
            next = a[19]
            a[19] = rotl(carried, 56)
            carried = next
            next = a[13]
            a[13] = rotl(carried, 8)
            carried = next
            next = a[12]
            a[12] = rotl(carried, 25)
            carried = next
            next = a[2]
            a[2] = rotl(carried, 43)
            carried = next
            next = a[20]
            a[20] = rotl(carried, 62)
            carried = next
            next = a[14]
            a[14] = rotl(carried, 18)
            carried = next
            next = a[22]
            a[22] = rotl(carried, 39)
            carried = next
            next = a[9]
            a[9] = rotl(carried, 61)
            carried = next
            next = a[6]
            a[6] = rotl(carried, 20)
            carried = next
            next = a[1]
            a[1] = rotl(carried, 44)
            carried = next
            // Chi.
            for row in stride(from: 0, to: 25, by: 5) {
                let (b0, b1, b2, b3, b4) = (a[row], a[row + 1], a[row + 2], a[row + 3], a[row + 4])
                a[row] = b0 ^ (~b1 & b2)
                a[row + 1] = b1 ^ (~b2 & b3)
                a[row + 2] = b2 ^ (~b3 & b4)
                a[row + 3] = b3 ^ (~b4 & b0)
                a[row + 4] = b4 ^ (~b0 & b1)
            }
            a[0] ^= constants[round]
        }
    }

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
}

/// BLAKE3, after the reference implementation of its authors: 1024-byte chunks hashed in
/// 64-byte blocks and joined in a binary tree.
///
/// Nothing is allocated per block: the working state lives in raw memory or on the stack. The
/// chunks of large inputs are hashed on all cores, each core taking a subtree of equal size, which
/// is correct because the chaining value of such a subtree does not depend on what is around it.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class BLAKE3Hasher: StreamHasher, @unchecked Sendable {
    private static let chunkStart: UInt32 = 1, chunkEnd: UInt32 = 2, parent: UInt32 = 4, root: UInt32 = 8
    private static let chunkSize = 1_024

    /// Filled once, when first used, and only read afterwards.
    nonisolated(unsafe) private static let iv: UnsafePointer<UInt32> = {
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
    nonisolated(unsafe) private static let schedule: UnsafePointer<UInt8> = {
        let permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
        var order = Array(0..<16)
        var all: [UInt8] = []
        for _ in 0..<7 {
            all += order.map { UInt8($0) }
            order = permutation.map { order[$0] }
        }
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: all.count)
        pointer.initialize(from: all, count: all.count)
        return UnsafePointer(pointer)
    }()

    /// Inputs of at least this many chunks are split over the cores.
    private static let parallelChunks = 16

    // MARK: The compression function

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x &>> n) | (x &<< (32 &- n)) }

    @inline(__always)
    private static func mix(
        _ s: UnsafeMutablePointer<UInt32>,
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int,
        _ x: UInt32,
        _ y: UInt32
    ) {
        s[a] = s[a] &+ s[b] &+ x
        s[d] = rotr(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]
        s[b] = rotr(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b] &+ y
        s[d] = rotr(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]
        s[b] = rotr(s[b] ^ s[c], 7)
    }

    /// Compresses one block `m` (16 words) under the chaining value `value` (8 words) into
    /// `s`, 16 words: the first eight are the new chaining value, all sixteen the output
    /// of a root.
    private static func compress(
        _ value: UnsafePointer<UInt32>,
        _ m: UnsafePointer<UInt32>,
        _ counter: UInt64,
        _ blockLength: UInt32,
        _ flags: UInt32,
        _ s: UnsafeMutablePointer<UInt32>
    ) {
        for index in 0..<8 { s[index] = value[index] }
        for index in 0..<4 { s[8 + index] = iv[index] }
        s[12] = UInt32(truncatingIfNeeded: counter)
        s[13] = UInt32(truncatingIfNeeded: counter >> 32)
        s[14] = blockLength
        s[15] = flags
        let order = schedule
        for round in 0..<7 {
            let o = round * 16
            mix(s, 0, 4, 8, 12, m[Int(order[o])], m[Int(order[o + 1])])
            mix(s, 1, 5, 9, 13, m[Int(order[o + 2])], m[Int(order[o + 3])])
            mix(s, 2, 6, 10, 14, m[Int(order[o + 4])], m[Int(order[o + 5])])
            mix(s, 3, 7, 11, 15, m[Int(order[o + 6])], m[Int(order[o + 7])])
            mix(s, 0, 5, 10, 15, m[Int(order[o + 8])], m[Int(order[o + 9])])
            mix(s, 1, 6, 11, 12, m[Int(order[o + 10])], m[Int(order[o + 11])])
            mix(s, 2, 7, 8, 13, m[Int(order[o + 12])], m[Int(order[o + 13])])
            mix(s, 3, 4, 9, 14, m[Int(order[o + 14])], m[Int(order[o + 15])])
        }
        for index in 0..<8 {
            s[index] ^= s[index + 8]
            s[index + 8] ^= value[index]
        }
    }

    // MARK: Chunks and parents

    /// The chaining value (8 words) of a chunk of `length` bytes (1…1024).
    ///
    /// With `isRoot` the chunk is the whole input and the eight words are the start of the digest.
    private static func chunk(
        _ input: UnsafeRawPointer,
        length: Int,
        counter: UInt64,
        isRoot: Bool,
        into out: UnsafeMutablePointer<UInt32>
    ) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 40) { scratch in
            let value = scratch.baseAddress!
            let m = value + 8
            let s = value + 24
            for index in 0..<8 { value[index] = iv[index] }
            let blocks = max(1, (length + 63) / 64)
            for block in 0..<blocks {
                let offset = block * 64
                let blockLength = min(64, length - offset)
                if blockLength == 64 {
                    for index in 0..<16 {
                        m[index] = UInt32(
                            littleEndian: input.loadUnaligned(fromByteOffset: offset + index * 4, as: UInt32.self)
                        )
                    }
                } else {
                    for index in 0..<16 { m[index] = 0 }
                    UnsafeMutableRawPointer(m).copyMemory(from: input + offset, byteCount: blockLength)
                }
                var flags: UInt32 = block == 0 ? chunkStart : 0
                if block == blocks - 1 { flags |= chunkEnd | (isRoot ? root : 0) }
                compress(value, m, counter, UInt32(blockLength), flags, s)
                for index in 0..<8 { value[index] = s[index] }
            }
            for index in 0..<8 { out[index] = value[index] }
        }
    }

    /// The chaining value (8 words) of the parent of two subtrees; with `isRoot` the start of the digest.
    /// `out` may be one of the two.
    private static func join(
        _ left: UnsafePointer<UInt32>,
        _ right: UnsafePointer<UInt32>,
        isRoot: Bool,
        into out: UnsafeMutablePointer<UInt32>
    ) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 32) { scratch in
            let m = scratch.baseAddress!
            let s = m + 16
            for index in 0..<8 {
                m[index] = left[index]
                m[index + 8] = right[index]
            }
            compress(iv, m, 0, 64, parent | (isRoot ? root : 0), s)
            for index in 0..<8 { out[index] = s[index] }
        }
    }

    /// The chaining value of `chunks` (a power of two) whole chunks, on this thread.
    private static func serialSubtree(
        _ input: UnsafeRawPointer,
        chunks: Int,
        counter: UInt64,
        into out: UnsafeMutablePointer<UInt32>
    ) {
        if chunks == 1 {
            chunk(input, length: chunkSize, counter: counter, isRoot: false, into: out)
            return
        }
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 16) { pair in
            let left = pair.baseAddress!
            let right = left + 8
            let half = chunks / 2
            serialSubtree(input, chunks: half, counter: counter, into: left)
            serialSubtree(input + half * chunkSize, chunks: half, counter: counter + UInt64(half), into: right)
            join(left, right, isRoot: false, into: out)
        }
    }

    /// Like `serialSubtree`, but a large subtree is cut into equal parts that the cores hash
    /// side by side; their chaining values are joined here.
    private static func subtree(
        _ input: UnsafeRawPointer,
        chunks: Int,
        counter: UInt64,
        into out: UnsafeMutablePointer<UInt32>
    ) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var parts = 1
        while parts * 2 <= cores * 2, parts * 2 <= chunks / 4 { parts *= 2 }
        guard chunks >= parallelChunks, parts > 1 else {
            serialSubtree(input, chunks: chunks, counter: counter, into: out)
            return
        }
        let size = chunks / parts
        let values = UnsafeMutablePointer<UInt32>.allocate(capacity: parts * 8)
        defer { values.deallocate() }
        let source = UncheckedPointer(input)
        let target = UncheckedPointer(values)
        DispatchQueue.concurrentPerform(iterations: parts) { index in
            serialSubtree(
                source.pointer + index * size * chunkSize,
                chunks: size,
                counter: counter + UInt64(index * size),
                into: target.pointer + index * 8
            )
        }
        var count = parts
        while count > 1 {
            for index in 0..<(count / 2) {
                join(values + index * 16, values + index * 16 + 8, isRoot: false, into: values + index * 8)
            }
            count /= 2
        }
        for index in 0..<8 { out[index] = values[index] }
    }

    /// A pointer handed to the threads of `subtree`; they work on separate parts of it.
    private struct UncheckedPointer<Pointee>: @unchecked Sendable {
        let pointer: Pointee
        init(_ pointer: Pointee) { self.pointer = pointer }
    }

    // MARK: The hasher

    /// The last (possibly full) chunk of the input so far.
    ///
    /// A full chunk is closed only when more input follows: the last one is the root's.
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: BLAKE3Hasher.chunkSize, alignment: 8)
    private var bufferLength = 0
    private var chunkCounter: UInt64 = 0
    /// The chaining values of finished subtrees (8 words each), the largest first.
    private let stack = UnsafeMutablePointer<UInt32>.allocate(capacity: 64 * 8)
    private var stackCount = 0

    deinit {
        buffer.deallocate()
        stack.deallocate()
    }

    /// A finished subtree of `2^level` chunks joins the tree: for every pair of equal subtrees
    /// that is complete now (one per trailing zero bit of the chunk count) a parent takes their place.
    private func add(_ value: UnsafeMutablePointer<UInt32>, level: Int) {
        var total = (chunkCounter + (1 << UInt64(level))) >> UInt64(level)
        chunkCounter += 1 << UInt64(level)
        while total & 1 == 0, stackCount > 0 {
            stackCount -= 1
            Self.join(stack + stackCount * 8, value, isRoot: false, into: value)
            total >>= 1
        }
        (stack + stackCount * 8).update(from: value, count: 8)
        stackCount += 1
    }

    private func closeBufferedChunk() {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { value in
            Self.chunk(
                buffer,
                length: Self.chunkSize,
                counter: chunkCounter,
                isRoot: false,
                into: value.baseAddress!
            )
            add(value.baseAddress!, level: 0)
        }
        bufferLength = 0
    }

    internal func update(_ data: Data) {
        data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard let base = input.baseAddress, input.count > 0 else {
                return
            }
            let size = Self.chunkSize
            var offset = 0
            // More input follows a full chunk that was held back.
            if bufferLength == size { closeBufferedChunk() }
            if bufferLength > 0 {
                let take = min(size - bufferLength, input.count)
                (buffer + bufferLength).copyMemory(from: base, byteCount: take)
                bufferLength += take
                offset = take
                if offset == input.count {
                    return
                }
                closeBufferedChunk()
            }
            // Whole chunks that are followed by at least one more byte, as subtrees as large
            // as the position in the tree allows.
            var chunks = (input.count - offset - 1) / size
            while chunks > 0 {
                var level = 0
                while 1 << (level + 1) <= chunks, chunkCounter % (1 << UInt64(level + 1)) == 0 { level += 1 }
                withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { value in
                    Self.subtree(
                        base + offset,
                        chunks: 1 << level,
                        counter: chunkCounter,
                        into: value.baseAddress!
                    )
                    add(value.baseAddress!, level: level)
                }
                offset += size << level
                chunks -= 1 << level
            }
            buffer.copyMemory(from: base + offset, byteCount: input.count - offset)
            bufferLength = input.count - offset
        }
    }

    internal func finish() -> [UInt8] {
        var words = [UInt32](repeating: 0, count: 16)
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { value in
            let value = value.baseAddress!
            Self.chunk(
                buffer,
                length: bufferLength,
                counter: chunkCounter,
                isRoot: stackCount == 0,
                into: value
            )
            // The last chunk is joined with the finished subtrees from the smallest up.
            for index in stride(from: stackCount - 1, through: 0, by: -1) {
                Self.join(stack + index * 8, value, isRoot: index == 0, into: value)
            }
            for index in 0..<8 { words[index] = value[index] }
        }
        return words.prefix(8).flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) } }
    }
}
