import AFMKernel
import Foundation
import StressKit

@testable import ViewerPlugin

/// Threads that call the document as the contract allows ("safe to call from several threads").
///
/// They ask for rows, the row of an offset, the row of a line, text of a range, and search; many of the
/// calls are cancelled from yet another thread after a random moment.
///
/// Unchecked: `stopped` and `stats` are only read and written with `lock` held; the rest is immutable.
internal final class Hammer: @unchecked Sendable {
    /// The document the threads call.
    internal let document: TextDocument
    /// The columns of its layout.
    internal let columns: Int
    /// Names the hammer in failures and figures.
    internal let label: String
    /// Guards `stopped` and `stats`.
    private let lock = NSLock()
    /// Whether the threads are to end.
    private var stopped = false
    /// The figures of each kind of call.
    private var stats: [String: OpStats] = [:]
    /// Entered by every thread, left when it ends.
    private let group = DispatchGroup()

    /// Whether the threads are to end.
    internal var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// A hammer on `document`, laid out at `columns`.
    internal init(_ document: TextDocument, columns: Int, label: String) {
        self.document = document
        self.columns = columns
        self.label = label
    }

    /// Checks rows asked for from row `first`: numbered in order, contiguous, as wide as the layout at most,
    /// inside the content.
    internal func check(_ rows: [DisplayRow], first: Int, flagCancelled _: Bool) {
        for (position, row) in rows.enumerated() {
            if row.index != first + position {
                fail("\(label): row number", "asked from \(first), got index \(row.index) at position \(position)")
            }
            if position > 0, row.range.lowerBound != rows[position - 1].range.upperBound {
                let before = rows[position - 1].range.upperBound
                fail(
                    "\(label): rows not contiguous",
                    "row \(row.index) begins at \(row.range.lowerBound), the one before ends at \(before)"
                )
            }
            if row.text.utf16.count > columns * 2 {
                fail(
                    "\(label): row wider than the layout",
                    "row \(row.index) has \(row.text.utf16.count) units, layout \(columns)"
                )
            }
            let content = document.content
            if row.range.upperBound > content.upperBound || row.range.lowerBound < content.lowerBound {
                fail("\(label): row outside the content", "row \(row.index) \(row.range)")
            }
        }
    }

    /// Starts `threads` readers and `searchers` searchers (fewer when the environment says so).
    internal func start(threads: Int, searchers: Int, seed: UInt64) {
        let readers = Options.noHammer ? 0 : threads
        let finders = Options.noHammer || Options.noSearchers ? 0 : searchers
        for index in 0..<readers + finders {
            group.enter()
            let thread = Thread { [self] in
                work(index: index, readers: readers, seed: seed)
            }
            thread.name = "Stress.Hammer"
            thread.start()
        }
    }

    /// Stops the threads and waits for them, pumping the main run loop.
    ///
    /// Returns false when they do not end within 60 s.
    @MainActor
    @discardableResult
    internal func stop() -> Bool {
        lock.lock()
        stopped = true
        lock.unlock()
        let done = Shared(false)
        group.notify(queue: .main) { done.value = true }
        return pump(upTo: 60) { done.value }
    }

    /// Prints the figures of each kind of call.
    internal func report() {
        lock.lock()
        let copy = stats
        lock.unlock()
        for (operation, entry) in copy.sorted(by: { $0.key < $1.key }) {
            let mean = entry.total / Double(max(1, entry.count)) * 1_000
            say(
                "  " + pad("[\(label)] \(operation)", 58)
                    + String(
                        format: " n=%7d mean=%8.3fms max=%9.1fms cancelled=%d threw=%d",
                        entry.count,
                        mean,
                        entry.maxMs,
                        entry.cancelled,
                        entry.threw
                    )
            )
        }
    }

    /// Adds one call of `operation` to the figures.
    internal func note(_ operation: String, _ seconds: Double, cancelled: Bool, threw: Bool) {
        lock.lock()
        var entry = stats[operation] ?? OpStats()
        entry.count += 1
        entry.total += seconds
        entry.maxMs = max(entry.maxMs, seconds * 1_000)
        if cancelled {
            entry.cancelled += 1
        }
        if threw {
            entry.threw += 1
        }
        stats[operation] = entry
        lock.unlock()
    }

    /// One thread: calls until stopped, then leaves the group.
    private func work(index: Int, readers: Int, seed: UInt64) {
        var random = Random(seed: seed &* 1_000 &+ UInt64(index))
        let isSearcher = index >= readers
        while !isStopped {
            autoreleasepool {
                oneCall(isSearcher: isSearcher, random: &random)
            }
        }
        group.leave()
    }

    deinit {
        // Nothing to release.
    }
}
