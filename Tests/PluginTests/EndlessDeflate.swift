import Foundation

@testable import ArchivesPlugin

/// Stored deflate blocks of zeros without end: a stream that decompresses for as long as it
/// is read from, which no real archive does.
///
/// Unchecked: read by one thread at a time, as a stream is.
internal final class EndlessDeflate: ByteStream, @unchecked Sendable {
    /// How many reads were made so far; read from another thread to know when the stream is busy.
    internal let reads = SharedCounter()
    private var block = Data()

    /// Up to `count` bytes of the next stored block, starting a new block when the last one was read.
    internal func read(upToCount count: Int) -> Data? {
        reads.add(1)
        // Not final, stored, 65535 bytes (and the complement of that number).
        if block.isEmpty { block = Data([0x00, 0xFF, 0xFF, 0x00, 0x00]) + Data(count: 0xFFFF) }
        let part = block.prefix(count)
        block = block.dropFirst(part.count)
        return Data(part)
    }

    /// Does nothing: the stream holds no resource.
    internal func close() {
        // Nothing to release.
    }

    deinit {
        // Nothing to release.
    }
}
