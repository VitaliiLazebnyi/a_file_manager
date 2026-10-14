import Foundation

/// A count that work on many threads adds to, and the threads it was added from.
///
/// Unchecked: all state is guarded by `lock`.
internal final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var threads = Set<UInt64>()

    /// The count so far.
    internal var count: Int { lock.withLock { value } }

    /// How many different threads called `note()`.
    internal var threadCount: Int { lock.withLock { threads.count } }

    /// Adds one, from any thread.
    internal func add() {
        lock.withLock { value += 1 }
    }

    /// Adds one and notes the calling thread.
    internal func note() {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        lock.withLock {
            threads.insert(id)
            value += 1
        }
    }

    deinit {
        // Nothing to release.
    }
}
