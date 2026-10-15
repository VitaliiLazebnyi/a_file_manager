import Foundation

/// The room on disk that block caches share: all of them together keep at most `limit` bytes.
///
/// `held` is guarded by `lock`; `limit` is immutable.
internal final class DiskBudget: @unchecked Sendable {
    /// What every cache of the viewer shares.
    internal static let shared = DiskBudget(limit: 2 << 30)

    /// The most all caches together hold.
    internal let limit: Int64
    private let lock = NSLock()
    private var held: Int64 = 0

    /// Bytes all caches hold now.
    internal var heldBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// A budget of `limit` bytes, none of them taken.
    internal init(limit: Int64) {
        self.limit = limit
    }

    /// Takes room for `bytes`; false when there is not that much left.
    internal func reserve(_ bytes: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard held + bytes <= limit else {
            return false
        }
        held += bytes
        return true
    }

    /// Gives room for `bytes` back.
    internal func release(_ bytes: Int64) {
        lock.lock()
        held -= bytes
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
