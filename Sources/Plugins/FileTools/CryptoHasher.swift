import CryptoKit
import Foundation

/// MD5 and the SHA-1/SHA-2 hashes of CryptoKit.
///
/// Unchecked `Sendable`: used by one thread at a time, as `StreamHasher` allows.
internal final class CryptoHasher<Function: HashFunction>: StreamHasher, @unchecked Sendable {
    /// CryptoKit's hash so far.
    private var function = Function()

    /// Adds the next block.
    internal func update(_ data: Data) { function.update(data: data) }

    /// The digest.
    internal func finish() -> [UInt8] { Array(function.finalize()) }

    deinit {
        // Nothing to release.
    }
}
