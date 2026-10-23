import Foundation

/// The memory budget of a search's walk: counts what is listed and not yet reported, and knows the
/// folder the reporting thread waits for and whether the walk was stopped.
///
/// Guarded by `lock`, a leaf lock: nothing else is taken while it is held (the job stack and the
/// reporting thread ask it from inside their own).
internal final class SearchBudget {
    private let lock = NSLock()
    private let limit: Int
    private var undelivered = 0
    private var needed: SearchNode?
    private var stopped = false

    /// Whether the walk was stopped (`stop()`).
    internal var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// A budget of `limit` entries listed and not yet reported.
    internal init(limit: Int) {
        self.limit = limit
    }

    /// Marks the walk as stopped.
    internal func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// Counts `change` more entries listed and not reported (fewer, when negative: they were reported).
    internal func adjust(by change: Int) {
        lock.lock()
        undelivered += change
        lock.unlock()
    }

    /// Notes the folder the reporting thread waits for (nil: none).
    internal func setNeeded(_ node: SearchNode?) {
        lock.lock()
        needed = node
        lock.unlock()
    }

    /// Whether `job` waits: a folder listing waits while the budget is used up, unless the
    /// reporting thread is waiting for exactly that folder.
    internal func holdsBack(_ job: SearchJobStack.Job) -> Bool {
        guard job.isListing else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return undelivered >= limit && job.node !== needed
    }

    deinit {
        // Nothing to release.
    }
}
