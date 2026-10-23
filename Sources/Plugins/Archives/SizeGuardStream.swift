import Foundation

/// Lets through no more than a member is said to hold.
///
/// A member that unpacks to more than its directory entry declares is damaged or made to fill the
/// disk; it is stopped at the first byte too many instead of after the last.
internal final class SizeGuardStream: ByteStream {
    private let source: any ByteStream
    private var left: UInt64
    private let name: String

    /// Passes on `source` for as long as it stays within `limit` bytes; `name` is the member's, for the error.
    internal init(_ source: any ByteStream, limit: UInt64, name: String) {
        self.source = source
        left = limit
        self.name = name
    }

    /// The source's next block; throws `ArchiveError.damaged` when it would go past the limit.
    internal func read(upToCount count: Int) throws -> Data? {
        guard let block = try source.read(upToCount: count) else {
            return nil
        }
        guard UInt64(block.count) <= left else {
            throw ArchiveError.damaged("\(name) holds more data than its entry says")
        }
        left -= UInt64(block.count)
        return block
    }

    /// Closes the source.
    internal func close() { source.close() }

    deinit {
        // Nothing to release.
    }
}
