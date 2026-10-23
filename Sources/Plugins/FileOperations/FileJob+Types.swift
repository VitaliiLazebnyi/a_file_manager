import AFMKernel
import Foundation
import os

/// The small types a job works with: the outcome of an item, the plan for a file, what one
/// file in progress carries, and the pool and batches of the workers.
extension FileJob {
    /// A source of a move whose removal waits for the commit of the target (`defersRemovals`).
    internal struct DeferredRemoval {
        /// The source to remove.
        internal let url: URL
        /// Whether it is a folder, removed only when empty.
        internal let isFolder: Bool
        /// The job's own source that `url` lies below; nil for such a source itself.
        internal let tree: URL?
    }

    /// The job is being stopped: by the user, by an answer (Abort, Cancel) or because its delegate is gone.
    internal struct Cancelled: Error {}

    /// Size of a subtree: files plus folders, and the bytes of the files.
    internal struct Measure {
        /// Files and folders.
        internal var items = 0
        /// The bytes of the files.
        internal var bytes: Int64 = 0

        /// The two sizes together; the bytes stop at the largest number rather than overflow.
        internal static func + (lhs: Self, rhs: Self) -> Self {
            Self(items: lhs.items + rhs.items, bytes: lhs.bytes.addingSaturated(rhs.bytes))
        }

        /// Adds `rhs` to `lhs`.
        internal static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
    }

    /// How one item ended.
    internal struct Outcome {
        /// Not processed: nothing changed.
        internal static let skipped = Self(finished: false, emptied: false, target: nil)

        /// Processed as far as the user is concerned; the panel deselects it.
        internal var finished: Bool
        /// Nothing of it is left at the source that a move would have to keep.
        internal var emptied: Bool
        /// Where it went; nil when it went nowhere.
        internal var target: URL?
    }

    /// What was decided for a file whose turn has come.
    ///
    /// Skipping is no plan: the planner answers nil.
    internal enum Plan {
        /// The source is added to the end of the file at the target.
        case append(URL)
        /// The target is the source itself under another spelling of its name: a rename, and
        /// never anything that reads and writes the file.
        case rename(URL)
        /// The file at the target is the beginning of the source; the rest is added.
        case resume(URL)
        /// The file is written to the target, over what is there when `replacing`.
        case write(URL, replacing: Bool)

        /// The location the plan writes to.
        internal var target: URL {
            switch self {
            case .write(let url, _), .rename(let url), .append(let url), .resume(let url):
                return url
            }
        }

        /// Whether the plan is a rename onto another spelling of the same name.
        internal var isRename: Bool {
            if case .rename = self {
                return true
            }
            return false
        }
    }

    /// Where an item stands in the walk of a copy or move: the batch of its folder and its place
    /// there, where the copy filter stands, how deep it lies, and the job's own source it lies below.
    internal struct Place: Sendable {
        /// The batch the item's outcome goes to.
        internal let batch: Batch
        /// The item's place in the batch.
        internal let slot: Int
        /// Where the copy filter stands in the folder that holds the item.
        internal let position: CopyFilter.Position
        /// The job's own source that the item lies below; nil for such a source itself.
        internal let tree: URL?
        /// How many folders down from the job's own source the item lies.
        internal let depth: Int

        /// Whether the item is one of the job's own sources, whose targets are checked against them.
        internal var isTopLevel: Bool { tree == nil }
    }

    /// The bytes one file in progress has contributed to the progress so far.
    ///
    /// It belongs to the thread that copies the file and changes under `counters`.
    internal final class Flight {
        /// The bytes of this file the progress counts so far.
        internal var bytes: Int64 = 0
        /// The origin mark the file gets from its source (see `originMark`).
        internal var origin: Data?
        /// What a failed try left under the real name ("keep partial files"), and how long it was.
        internal var partial: (url: URL, size: Int64)?

        deinit {
            // Nothing to release.
        }
    }

    /// The workers that copy small files side by side.
    ///
    /// They run on the kernel's threads for work that blocks (`BlockingCalls.run`), not on a
    /// dispatch queue: a worker waits for a disk, and a disk that has stopped answering must not
    /// take threads from the queues the rest of the program shares.
    internal final class Pool: Sendable {
        /// One for each worker that may run; the caller takes one before `start`.
        internal let slots: DispatchSemaphore
        /// How many workers run at most.
        private let width: Int

        /// A pool of `width` workers.
        internal init(width: Int) {
            self.width = width
            slots = DispatchSemaphore(value: width)
        }

        /// Takes the work out of `task` and runs it.
        ///
        /// The work is let go of when this returns: a local that held it until the end of the
        /// closure in `start` would still hold the job while the group is left.
        private static func runOnce(_ task: OSAllocatedUnfairLock<(@Sendable () -> Void)?>) {
            let taken = task.withLock { work in
                defer { work = nil }
                return work
            }
            taken?()
        }

        /// Starts `work` on a thread of its own; `group` is left when it has returned, and
        /// the worker's slot (taken by the caller beforehand) is given back.
        ///
        /// The work, and all it holds (the job), is let go of before the group is left: whoever
        /// waits for the group finds nothing of the job left on the worker's thread.
        internal func start(in group: DispatchGroup, _ work: @escaping @Sendable () -> Void) {
            group.enter()
            let task = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: work)
            BlockingCalls.run { [slots] in
                Self.runOnce(task)
                slots.signal()
                group.leave()
            }
        }

        /// Returns when no worker is busy any more: every slot is taken once and given back.
        ///
        /// Job thread only.
        internal func drain() {
            for _ in 0..<width { slots.wait() }
            for _ in 0..<width { slots.signal() }
        }

        deinit {
            // Nothing to release: every worker has given its slot back.
        }
    }

    /// The items of one folder (or the job's sources): where their outcomes are collected
    /// while some of them are still being copied by the pool.
    ///
    /// Unchecked `Sendable`: the outcomes and `cancelled` are guarded by `lock`; the other
    /// properties are used by the job thread only.
    internal final class Batch: @unchecked Sendable {
        /// The workers of this batch; left by each when its item is done.
        internal let group = DispatchGroup()
        /// Guards `outcomes` and `cancelled`.
        private let lock = NSLock()
        /// How each item ended, by its place; nil while it is not done.
        private var outcomes: [Outcome?]
        /// Whether a worker of the batch ended the job.
        private var cancelled = false
        /// The targets this batch has given out so far (hashes of their `claimKey`): written,
        /// or still being written by a worker.
        ///
        /// Job thread only.
        internal var produced: Set<Int> = []
        /// The folder this batch writes into has received files of this job before.
        internal var isShared = false
        /// Whether `staysOnVolume` is known yet.
        ///
        /// Job thread only.
        internal var knowsVolume = false
        /// Whether a move within this batch stays on one volume, once `knowsVolume`.
        ///
        /// Job thread only.
        internal var staysOnVolume = false
        /// The items are copied one after another, in the order they come: their file system
        /// asked for that order (`readOrder(of:)`), which several readers at once would undo.
        internal var isSerial = false

        /// A batch of `count` items, none done yet.
        internal init(count: Int) { outcomes = Array(repeating: nil, count: count) }

        /// Notes how the item at `slot` ended; any thread.
        internal func set(_ slot: Int, _ outcome: Outcome) {
            lock.lock()
            outcomes[slot] = outcome
            lock.unlock()
        }

        /// Notes that a worker of the batch ended the job; any thread.
        internal func setCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        /// Waits for the workers and returns what is known; an item without an outcome was not reached.
        internal func settled() -> (outcomes: [Outcome?], cancelled: Bool) {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            return (outcomes, cancelled)
        }

        deinit {
            // Nothing to release: the workers are done when the batch goes.
        }
    }
}
