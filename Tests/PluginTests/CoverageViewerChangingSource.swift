import Foundation

@testable import ViewerPlugin

/// A file whose bytes can be replaced (same length) and whose reads of a range can fail, as a
/// file that changes while it is shown and a volume that fails for a while do.
///
/// `content` and `failing` are guarded by `lock`.
internal final class CoverageViewerChangingSource: ByteSource, @unchecked Sendable {
    /// The length the file had when it was opened.
    internal let length: Int64
    private let lock = NSLock()
    private var content: Data
    private var failing: Range<Int64>?

    /// Starts with `content`.
    internal init(_ content: Data) {
        self.content = content
        length = Int64(content.count)
    }

    /// From now on the file holds `replacement`.
    internal func replace(with replacement: Data) {
        lock.lock()
        content = replacement
        lock.unlock()
    }

    /// Reads that touch `range` fail from now on; nil ends that.
    internal func fail(_ range: Range<Int64>?) {
        lock.lock()
        failing = range
        lock.unlock()
    }

    /// The bytes from `offset` on, unless the read touches the failing range.
    internal func read(at offset: Int64, count: Int) throws -> Data {
        lock.lock()
        let (bytes, broken) = (content, failing)
        lock.unlock()
        if let broken, offset < broken.upperBound, offset + Int64(count) > broken.lowerBound {
            throw CocoaError(.fileReadUnknown)
        }
        let lower = Int(min(max(0, offset), Int64(bytes.count)))
        return bytes.subdata(in: lower..<min(bytes.count, lower + max(0, count)))
    }

    deinit {
        // Nothing to release.
    }
}
