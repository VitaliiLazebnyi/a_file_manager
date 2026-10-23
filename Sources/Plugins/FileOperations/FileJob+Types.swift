import AFMContracts
import AFMKernel
import Foundation
import os

extension FileJob {
    internal struct DeferredRemoval {
        let url: URL
        let isFolder: Bool
        /// The job's own source that `url` lies below; nil for such a source itself.
        let tree: URL?
    }

    internal struct Cancelled: Error {}

    /// Size of a subtree: files plus folders, and the bytes of the files.
    internal struct Measure {
        var items = 0
        var bytes: Int64 = 0

        static func + (a: Self, b: Self) -> Self {
            Self(items: a.items + b.items, bytes: a.bytes.addingSaturated(b.bytes))
        }
        static func += (a: inout Self, b: Self) { a = a + b }
    }

    /// How one item ended.
    internal struct Outcome {
        static let skipped = Self(finished: false, emptied: false, target: nil)

        /// Processed as far as the user is concerned; the panel deselects it.
        var finished: Bool
        /// Nothing of it is left at the source that a move would have to keep.
        var emptied: Bool
        var target: URL?
    }

    /// What was decided for a file whose turn has come.
    ///
    /// Skipping is no plan: the planner answers nil.
    internal enum Plan {
        case write(URL, replacing: Bool)
        /// The target is the source itself under another spelling of its name: a rename, and
        /// never anything that reads and writes the file.
        case rename(URL)
        case append(URL)
        case resume(URL)

        var target: URL {
            switch self {
            case .write(let url, _), .rename(let url), .append(let url), .resume(let url):
                return url
            }
        }

        var isRename: Bool {
            if case .rename = self {
                return true
            }
            return false
        }
    }

    /// The bytes one file in progress has contributed to the progress so far.
    ///
    /// It belongs to the thread that copies the file and changes under `counters`.
    internal final class Flight {
        var bytes: Int64 = 0
        /// The origin mark the file gets from its source (see `originMark`).
        var origin: Data?
        /// What a failed try left under the real name ("keep partial files"), and how long it was.
        var partial: (url: URL, size: Int64)?
    }

    /// The workers that copy small files side by side.
    ///
    /// They run on the kernel's threads for work that blocks (`BlockingCalls.run`), not on a
    /// dispatch queue: a worker waits for a disk, and a disk that has stopped answering must not
    /// take threads from the queues the rest of the program shares.
    internal final class Pool: Sendable {
        let slots: DispatchSemaphore
        private let width: Int

        init(width: Int) {
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
        func start(in group: DispatchGroup, _ work: @escaping @Sendable () -> Void) {
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
        func drain() {
            for _ in 0..<width { slots.wait() }
            for _ in 0..<width { slots.signal() }
        }
    }

    /// The items of one folder (or the job's sources): where their outcomes are collected
    /// while some of them are still being copied by the pool.
    ///
    /// Unchecked `Sendable`: the outcomes and `cancelled` are guarded by `lock`; the other
    /// properties are used by the job thread only.
    internal final class Batch: @unchecked Sendable {
        let group = DispatchGroup()
        private let lock = NSLock()
        private var outcomes: [Outcome?]
        private var cancelled = false
        /// The targets this batch has given out so far (hashes of their `claimKey`): written,
        /// or still being written by a worker.
        ///
        /// Job thread only.
        var produced: Set<Int> = []
        /// The folder this batch writes into has received files of this job before.
        var isShared = false
        /// Whether a move within this batch stays on one volume, once known.
        ///
        /// Job thread only.
        var staysOnVolume: Bool?
        /// The items are copied one after another, in the order they come: their file system
        /// asked for that order (`readOrder(of:)`), which several readers at once would undo.
        var isSerial = false

        init(count: Int) { outcomes = Array(repeating: nil, count: count) }

        func set(_ slot: Int, _ outcome: Outcome) {
            lock.lock()
            outcomes[slot] = outcome
            lock.unlock()
        }

        func setCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        /// Waits for the workers and returns what is known; an item without an outcome was not reached.
        func settled() -> (outcomes: [Outcome?], cancelled: Bool) {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            return (outcomes, cancelled)
        }
    }
}
