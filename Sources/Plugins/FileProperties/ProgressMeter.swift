import AFMKernel
import Foundation

/// Counts finished items from any thread and passes the count on to a job's progress window:
/// at most twenty times a second, one thread at a time (the lock is held while reporting, so a
/// `JobMonitor`, which expects one reporting thread, sees one at a time).
///
/// Whichever thread comes by reports, because the job's own thread may be waiting for the others or
/// deep in one slow folder; a paused job then stops the threads that come by, which is what Pause
/// is for.
///
/// All state is guarded by `lock`.
internal final class ProgressMeter: @unchecked Sendable {
    private let monitor: any JobMonitor
    private let title: String
    private let total: Int
    private let lock = NSLock()
    private var done = 0
    private var lastReport = Date.distantPast

    /// A meter that reports to `monitor` under `title`.
    ///
    /// `total` is 0 when the number of items is not known in advance.
    internal init(_ monitor: any JobMonitor, title: String, total: Int) {
        self.monitor = monitor
        self.title = title
        self.total = total
    }

    /// Counts `count` more finished items and, unless the last report is less than a twentieth of
    /// a second old, reports them with `location` as the second line; any thread.
    internal func add(_ count: Int, at location: @autoclosure () -> String) {
        lock.lock()
        defer { lock.unlock() }
        done += count
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.05 else {
            return
        }
        lastReport = now
        monitor.report(JobProgress(lines: [title, location()], itemsDone: done, itemsTotal: total))
    }

    deinit {
        // Nothing to release.
    }
}
