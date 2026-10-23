import Foundation

/// How the progress of a copy reaches its caller.
extension LocalFileSystem {
    /// Hands the progress of a copy to the caller's closure for as long as the caller is
    /// there: a copy that was left behind finds nobody to report to, and stops.
    ///
    /// Unchecked: `report` is guarded by `lock`. The caller's closure is called on another
    /// thread only while the caller waits for the copy, and never once `detach` has returned.
    internal final class CopyReport: @unchecked Sendable {
        private let lock = NSLock()
        private var report: ((Int64) -> Bool)?

        /// Reports to `report` until `detach`.
        internal init(_ report: @escaping (Int64) -> Bool) { self.report = report }

        /// False when the copy is to stop.
        internal func callAsFunction(_ copied: Int64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return report?(copied) ?? false
        }

        /// The caller is leaving; returns once a report under way is over.
        internal func detach() {
            lock.lock()
            report = nil
            lock.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }
}
