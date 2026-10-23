import Foundation

/// The locked numbers the index and its builds share.
extension TextRowIndex {
    /// The numbers the main thread reads of an index.
    internal struct Counts {
        /// Rows known so far.
        internal var rows = 0
        /// Lines known so far.
        internal var lines = 0
        /// The rows of everything before this offset are known.
        internal var covered: Int64
        /// Whether the index is complete.
        internal var complete = false
        /// The first error that made a part of the file unreadable.
        internal var failure: (any Error)?
        /// How many segments the last build took over.
        internal var reused = 0
    }

    /// What the main thread asks for all the time (the scroller, the status line): a copy kept
    /// behind a lock of its own that is held for a few stores only, so the view never waits for a
    /// thread that is publishing a segment, or that has been preempted holding the index lock.
    ///
    /// All state is guarded by `guarded`.
    internal final class Overview: @unchecked Sendable {
        private let guarded = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        private var counts: Counts

        /// Rows known so far.
        internal var rowCount: Int { read { $0.rows } }
        /// Lines known so far.
        internal var lineCount: Int { read { $0.lines } }
        /// The rows of everything before this offset are known.
        internal var coveredEnd: Int64 { read { $0.covered } }
        /// Whether the index is complete.
        internal var isComplete: Bool { read { $0.complete } }
        /// The first error that made a part of the file unreadable.
        internal var failed: (any Error)? { read { $0.failure } }
        /// How many segments the last build took over.
        internal var reusedCount: Int { read { $0.reused } }

        /// An overview of an empty index whose text starts at `covered`.
        internal init(covered: Int64) {
            guarded.initialize(to: os_unfair_lock())
            counts = Counts(covered: covered)
        }

        /// Replaces all the numbers at once; any thread.
        internal func store(_ new: Counts) {
            os_unfair_lock_lock(guarded)
            counts = new
            os_unfair_lock_unlock(guarded)
        }

        private func read<T>(_ value: (Counts) -> T) -> T {
            os_unfair_lock_lock(guarded)
            defer { os_unfair_lock_unlock(guarded) }
            return value(counts)
        }

        deinit {
            guarded.deallocate()
        }
    }

    /// A number shared by the threads of a build.
    ///
    /// Guarded by `lock`.
    internal final class Locked<Value: AdditiveArithmetic>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        /// The number now.
        internal var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        /// A number that starts at `value`.
        internal init(_ value: Value) { stored = value }

        /// Adds `amount`; any thread.
        internal func add(_ amount: Value) {
            lock.lock()
            stored += amount
            lock.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }
}
