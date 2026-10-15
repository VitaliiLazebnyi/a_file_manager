import Dispatch
import Foundation

/// The jobs: what one call of `run` hands out.
extension ParallelPool {
    /// One call of `run`: a range of indexes handed out in pieces.
    ///
    /// Its counters are guarded by the pool's `condition`.
    internal final class Job: @unchecked Sendable {
        /// What is done for each index; let go of when the call ends.
        internal var body: (@Sendable (Int) -> Void)?
        /// The number of indexes.
        internal let count: Int
        /// Indexes taken in one piece: large inputs are handed out in runs, so the lock is
        /// not taken for every element.
        internal let grain: Int
        /// The first index not handed out yet.
        internal var next = 0
        /// Pieces being worked on.
        internal var inFlight = 0
        /// The job whose piece was running on the thread that opened this one.
        internal let parent: Job?
        /// Signalled when the caller sleeps until the last piece is done or work appears below.
        internal var sleeper: DispatchSemaphore?

        // What follows is kept by the top of a tree, for the whole tree.
        /// The main thread waits for this tree.
        internal let isForMain: Bool
        /// The urgency of whoever opened the tree, which the pool's threads take on for its pieces.
        internal let urgency: qos_class_t
        /// The pool's threads that are at a piece of this tree.
        internal var threads = 0
        /// Threads beyond the cores that the tree may have, because its pieces wait and get done.
        internal var allowance = 0
        /// Pieces done so far, and how many of them the last look knew of.
        internal var finished = 0, seenFinished = 0
        /// Scratch for a look: the threads the tree could still take.
        internal var room = 0

        /// The top of the tree this job belongs to; nil for the top itself.
        private let top: Job?

        /// The top of the tree this job belongs to, itself when it is the top.
        internal var root: Job { top ?? self }
        /// The pieces not handed out yet.
        internal var piecesLeft: Int { (count - next + grain - 1) / grain }

        /// A job of `count` indexes in pieces of `grain`, opened from a piece of `parent`.
        ///
        /// A job opened from no piece is the top of a tree: it notes whether the main thread
        /// opened it and the urgency of the thread that did.
        internal init(count: Int, grain: Int, parent: Job?, body: @escaping @Sendable (Int) -> Void) {
            (self.count, self.grain, self.parent, self.body) = (count, grain, parent, body)
            top = parent.map(\.root)
            isForMain = parent == nil && Thread.isMainThread
            urgency = parent == nil ? ParallelPool.urgencyOfCaller() : QOS_CLASS_UNSPECIFIED
        }

        /// Whether this job was opened, at any depth, from a piece of `ancestor`.
        internal func descends(from ancestor: Job) -> Bool {
            var above = parent
            while let job = above {
                if job === ancestor {
                    return true
                }
                above = job.parent
            }
            return false
        }

        deinit {
            // Nothing to release.
        }
    }
}
