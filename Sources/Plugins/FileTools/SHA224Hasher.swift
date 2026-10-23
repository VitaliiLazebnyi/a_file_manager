import CommonCrypto
import Foundation

/// SHA-224, which CryptoKit leaves out.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class SHA224Hasher: StreamHasher, @unchecked Sendable {
    /// CommonCrypto's state of the hash.
    private var context = CC_SHA256_CTX()

    /// A hasher at the start of its input.
    internal init() { CC_SHA224_Init(&context) }

    /// Adds the next block, in pieces of at most 1 GB (CommonCrypto counts in 32 bits).
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

    /// The 28 bytes of the digest.
    internal func finish() -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        CC_SHA224_Final(&digest, &context)
        return digest
    }

    deinit {
        // Nothing to release.
    }
}
