import AFMContracts
import AFMKernel
import Foundation
import os

extension FileJob {
    /// Whether enough time has passed for the next report.
    ///
    /// Called with `counters` held.
    internal var isDue: Bool {
        guard progressInterval > 0, lastReport != 0 else {
            return true
        }
        return DispatchTime.now().uptimeNanoseconds - lastReport >= UInt64(progressInterval * 1_000_000_000)
    }

    // MARK: Progress

    /// A new item is being worked on.
    internal func report(_ lines: [String]) {
        let due = counters.withLock { () -> Bool in
            currentLines = lines
            pendingLines = nil
            return isDue
        }
        if due { emit(force: false) }
    }

    /// The same, with the lines put together only if a report is really sent: most items of
    /// a big folder pass between two reports.
    internal func report(_ lines: @escaping () -> [String]) {
        let due = counters.withLock { () -> Bool in
            pendingLines = lines
            return isDue
        }
        if due { emit(force: false) }
    }

    /// `copied`: how much of the file this flight carries has arrived so far.
    internal func advance(_ flight: Flight, to copied: Int64) {
        let due = counters.withLock { () -> Bool in
            inFlightBytes += copied - flight.bytes
            flight.bytes = copied
            return isDue
        }
        if due { emit(force: false) }
    }

    /// The file of this flight is dealt with: it counts as done with its full size.
    internal func land(_ flight: Flight, _ measure: Measure) {
        counters.withLock {
            inFlightBytes -= flight.bytes
            flight.bytes = 0
            done += measure
        }
    }

    internal func add(_ measure: Measure) {
        counters.withLock { done += measure }
    }

    /// Tells the delegate where the job stands.
    ///
    /// The figures are taken under `counters`, the delegate is called under `delivery` only: the
    /// reports stay in order and one at a time, and a delegate that takes its time (a paused job
    /// waits in there) keeps no counter from being updated. Called without either lock held.
    internal func emit(force: Bool) {
        guard let delegate else {
            return
        }
        delivery.lock()
        defer { delivery.unlock() }
        let progress = counters.withLock { () -> JobProgress? in
            // Another thread may have reported while this one waited its turn.
            guard force || isDue else {
                return nil
            }
            lastReport = DispatchTime.now().uptimeNanoseconds
            if let pendingLines {
                currentLines = pendingLines()
                self.pendingLines = nil
            }
            return JobProgress(
                lines: currentLines,
                itemsDone: done.items,
                itemsTotal: total.items,
                bytesDone: done.bytes.addingSaturated(inFlightBytes),
                bytesTotal: total.bytes
            )
        }
        if let progress { delegate.job(self, progress: progress) }
    }
}
