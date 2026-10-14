import Foundation

/// Passes batches from the thread that lists to the thread that asked, one at a time: the
/// listing waits until the batch was taken and it is known whether more are wanted.
///
/// Unchecked: all state is guarded by `condition`.
internal final class ListingRelay: @unchecked Sendable {
    /// What the asker hears next.
    internal enum Event {
        /// The asker has left, or wanted no more: nothing follows.
        case abandoned
        /// A batch of entries.
        case batch([FileItem])
        /// The listing is over, with its outcome.
        case finished(Swift.Result<Void, any Error>?)
    }

    /// What the asker answered to a batch.
    private enum Answer {
        /// No more batches are wanted.
        case enough
        /// More batches are wanted.
        case more
        /// Not answered yet.
        case waiting
    }

    private let condition = NSCondition()
    /// The batch the asker has not taken yet.
    private var pending: [FileItem] = []
    /// Whether `pending` holds a batch.
    private var hasPending = false
    private var answer = Answer.waiting
    /// The outcome of the listing, once it is over.
    private var result: Swift.Result<Void, any Error>?
    private var isFinished = false
    /// Nobody takes batches any more: the asker has left, or wanted no more.
    private var isClosed = false

    /// Called by the listing: hands over a batch and waits for the answer; false when no
    /// more batches are wanted.
    internal func offer(_ items: [FileItem]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !isClosed else {
            return false
        }
        (pending, hasPending, answer) = (items, true, .waiting)
        condition.broadcast()
        while answer == .waiting, !isClosed { condition.wait() }
        defer { answer = .waiting }
        return !isClosed && answer == .more
    }

    /// Called by the asker: waits for the next thing to happen.
    internal func next() -> Event {
        condition.lock()
        defer { condition.unlock() }
        while !hasPending, !isFinished, !isClosed { condition.wait() }
        if isClosed {
            return .abandoned
        }
        guard hasPending else {
            return .finished(result)
        }
        let items = pending
        (pending, hasPending) = ([], false)
        return .batch(items)
    }

    /// Called by the asker after a batch: whether it wants more.
    internal func reply(_ wantsMore: Bool) {
        condition.lock()
        answer = wantsMore ? .more : .enough
        if !wantsMore { isClosed = true }
        condition.broadcast()
        condition.unlock()
    }

    /// Called when the listing is over.
    internal func finish(_ result: Swift.Result<Void, any Error>?) {
        condition.lock()
        (self.result, isFinished) = (result, true)
        condition.broadcast()
        condition.unlock()
    }

    /// Called when the asker leaves: the listing is told that no more is wanted.
    internal func abandon() {
        condition.lock()
        (isClosed, pending, hasPending) = (true, [], false)
        condition.broadcast()
        condition.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
