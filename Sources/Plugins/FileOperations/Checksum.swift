public import AFMKernel
import CryptoKit
public import Foundation

/// Checksums of file contents, read block by block through the file-system providers, so a
/// file of any size on any file system costs one megabyte of memory (spec 07 › Verify).
///
/// SHA-256 takes the place of the spec's MD5/BLAKE3: the processors of every Mac compute it in
/// hardware.
public enum Checksum {
    /// Nil when `isCancelled` said stop, or one of `flags` was set, before the end of the file;
    /// a read that waits for a server is ended by the flags.
    ///
    /// Blocks; not for the main thread.
    public static func sha256(
        of url: URL,
        in fileSystems: FileSystemRegistry,
        flags: [CancellationFlag] = [],
        isCancelled: () -> Bool = { false }
    ) throws -> Data? {
        let provider = try fileSystems.provider(for: url)
        // A pipe or a device has no contents to sum up, and opening it may never return.
        if FileIdentity.isSpecialNode(url, followingLinks: true) {
            throw FileJobError.specialFile(fileSystems.displayPath(url))
        }
        let reader = try flags.first.map { try provider.read(url, cancellation: $0) } ?? provider.read(url)
        defer { reader.close() }
        let tokens = flags.map { $0.interrupting(reader) }
        defer { withExtendedLifetime(tokens) {} }
        var hash = SHA256()
        do {
            // Each block in a pool of its own: on a thread that lives long the buffers of a
            // large file would otherwise all be kept until the thread ends.
            var stopped = false
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let block = try reader.read(upToCount: 1 << 20) else {
                    return false
                }
                if isCancelled() {
                    stopped = true
                    return false
                }
                hash.update(data: block)
                return true
            }) {}
            if stopped {
                return nil
            }
        } catch {
            if flags.contains(where: \.isCancelled) {
                return nil
            }
            throw error
        }
        return Data(hash.finalize())
    }

    /// Whether two files hold the same bytes; nil when cancelled.
    ///
    /// Files of different sizes are different without a byte being read; otherwise the two are read
    /// side by side on two cores.
    public static func sameContents(
        _ a: URL,
        _ b: URL,
        in fileSystems: FileSystemRegistry,
        flags: [CancellationFlag] = [],
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Bool? {
        // Asked with the caller's flag, where there is one: a file on a server that has stopped
        // answering must not hold the comparison once it is cancelled.
        let flag = flags.first
        if let first = UniqueName.item(at: a, in: fileSystems, flag),
            let second = UniqueName.item(at: b, in: fileSystems, flag),
            !first.isDirectory, !second.isDirectory
        {
            if let special = [first, second].first(where: \.isSpecial) {
                throw FileJobError.specialFile(fileSystems.displayPath(special.url))
            }
            if first.size != second.size {
                return false
            }
        }
        let digests = try withoutActuallyEscaping(isCancelled) { isCancelled in
            try Parallel.map([a, b]) { url in
                Result { try sha256(of: url, in: fileSystems, flags: flags, isCancelled: isCancelled) }
            }
            .map { try $0.get() }
        }
        guard let first = digests[0], let second = digests[1] else {
            return nil
        }
        return first == second
    }
}
