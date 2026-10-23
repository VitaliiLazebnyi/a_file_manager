import Foundation

@testable import ViewerPlugin

/// The bytes of a file that became shorter after it was opened: it still tells its old length,
/// but only the first bytes are there.
internal final class CoverageViewerShortSource: ByteSource {
    /// The length the file had.
    internal let length: Int64
    private let bytes: Data

    /// A file of `length` bytes of which only `available` (from 0) can still be read.
    internal init(length: Int64, available: Int) {
        self.length = length
        bytes = Data((0..<available).map { UInt8(truncatingIfNeeded: $0 % 251) })
    }

    /// The bytes there are from `offset` on, at most `count`.
    internal func read(at offset: Int64, count: Int) -> Data {
        let lower = Int(min(max(0, offset), Int64(bytes.count)))
        return bytes.subdata(in: lower..<min(bytes.count, lower + max(0, count)))
    }

    deinit {
        // Nothing to release.
    }
}
