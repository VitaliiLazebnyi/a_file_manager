import Foundation

/// Jobs of a search for a few threads, taken from the top of a stack so that the work follows the
/// order the results are wanted in.
///
/// Closing drops what is left, and anything pushed after. `stack` and `isClosed` are guarded by
/// `condition`; `shouldHold` is set once, before `start`.
internal final class SearchJobStack: @unchecked Sendable {
    /// One piece of work: listing a folder, or testing some of its entries.
    internal struct Job {
        /// The folder the job is for.
        internal let node: SearchNode?
        /// Lists a folder (as opposed to testing entries).
        internal let isListing: Bool
        /// Does the work, on a worker thread.
        internal let run: () -> Void

        /// A job for `node` that does `run`.
        internal init(node: SearchNode?, isListing: Bool, run: @escaping () -> Void) {
            self.node = node
            self.isListing = isListing
            self.run = run
        }
    }

    /// Asked about the job on top: true leaves it there for a while (the memory budget).
    internal var shouldHold: ((Job) -> Bool)?
    private let condition = NSCondition()
    private var stack: [Job] = []
    private var isClosed = false

    /// Starts `threads` workers, which take jobs until the stack is closed.
    internal func start(threads: Int) {
        for _ in 0..<threads {
            let thread = Thread { [self] in work() }
            thread.qualityOfService = .userInitiated
            // The workers keep their stack frames small, but a regular expression or a
            // decoder deserves more than a thread's default.
            thread.stackSize = 4 << 20
            thread.start()
        }
    }

    /// Puts `jobs` on top of the stack; `jobs[0]` is taken first.
    ///
    /// After `close` nothing is kept: a worker that was still listing a folder must not bring
    /// the walk back to life.
    internal func push(_ jobs: [Job]) {
        guard !jobs.isEmpty else {
            return
        }
        condition.lock()
        if !isClosed {
            stack.append(contentsOf: jobs.reversed())
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Closes the stack and returns the jobs that were left.
    internal func close() -> Any {
        condition.lock()
        isClosed = true
        let dropped = stack
        stack = []
        condition.broadcast()
        condition.unlock()
        return dropped
    }

    private func work() {
        while let next = take() {
            autoreleasepool { next.run() }
        }
    }

    /// The next job, once there is one that is not held back; nil when the stack is closed.
    private func take() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while !isClosed {
            guard let top = stack.last else {
                condition.wait()
                continue
            }
            guard let shouldHold, shouldHold(top) else {
                return stack.removeLast()
            }
            condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        return nil
    }

    deinit {
        // Nothing to release.
    }
}
