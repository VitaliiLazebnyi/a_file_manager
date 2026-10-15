import AFMKernel
import Foundation

@testable import ViewerPlugin

/// A reader of a source of bytes, so a file system can serve one: what holds or fails the
/// source holds or fails the reader.
///
/// Unchecked: `position` is used by one thread at a time, as the protocol allows.
internal final class CoverageViewerSourceReader: FileReader, @unchecked Sendable {
    private let source: any ByteSource
    private var position: Int64 = 0

    /// A reader of `source` from its start.
    internal init(_ source: any ByteSource) {
        self.source = source
    }

    /// The next bytes; empty at the end.
    internal func read(upToCount count: Int) throws -> Data? {
        let block = try source.read(at: position, count: count)
        position += Int64(block.count)
        return block
    }

    /// Goes to `offset`.
    internal func seek(to offset: UInt64) {
        position = Int64(offset)
    }

    /// Nothing is open.
    internal func close() {
        // Nothing to release.
    }

    deinit {
        // Nothing to release.
    }
}
