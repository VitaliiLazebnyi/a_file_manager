import Foundation

@testable import ViewerPlugin

/// Bytes in memory whose reads can be held: while held, every read waits until it is let go, as
/// a server that is slow to answer does; and whose reads can be made to fail.
///
/// `held`, `failing` and `waiting` are guarded by `condition`.
internal final class CoverageViewerHeldSource: ByteSource, @unchecked Sendable {
    /// The length of the bytes.
    internal let length: Int64
    private let bytes: Data
    private let condition = NSCondition()
    private var held = false
    /// Reads from this offset on wait while held.
    private var threshold: Int64 = 0
    private var failing = false
    private var waiting = 0

    /// How many reads wait now.
    internal var waitingReads: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiting
    }

    /// The bytes of `text`.
    internal init(_ text: String) {
        bytes = Data(text.utf8)
        length = Int64(bytes.count)
    }

    /// The bytes of `data`.
    internal init(_ data: Data) {
        bytes = data
        length = Int64(data.count)
    }

    /// From now on reads wait.
    internal func hold() {
        hold(from: 0)
    }

    /// From now on reads from `offset` on wait.
    internal func hold(from offset: Int64) {
        condition.lock()
        held = true
        threshold = offset
        condition.unlock()
    }

    /// The reads that wait go on, and the next do not wait.
    internal func release() {
        condition.lock()
        held = false
        condition.broadcast()
        condition.unlock()
    }

    /// From now on reads fail (`true`) or succeed again.
    internal func fail(_ fails: Bool) {
        condition.lock()
        failing = fails
        condition.unlock()
    }

    /// The bytes from `offset` on, once the reads are not held; a throw while they fail.
    internal func read(at offset: Int64, count: Int) throws -> Data {
        condition.lock()
        waiting += 1
        while held, offset >= threshold {
            condition.wait()
        }
        waiting -= 1
        let fails = failing
        condition.unlock()
        if fails {
            throw CocoaError(.fileReadUnknown)
        }
        let lower = Int(min(max(0, offset), length))
        return bytes.subdata(in: lower..<min(bytes.count, lower + max(0, count)))
    }

    deinit {
        // Nothing to release.
    }
}
