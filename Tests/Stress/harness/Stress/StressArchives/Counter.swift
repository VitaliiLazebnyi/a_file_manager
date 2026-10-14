import Foundation
import StressKit

/// Named counts and timings, from any thread.
///
/// Unchecked: `counts` and `times` are only touched while `lock` is held.
internal final class Counter: @unchecked Sendable {
    /// The one counter of the process.
    internal static let shared = Counter()

    /// Guards `counts` and `times`.
    private let lock = NSLock()
    /// The counts by name.
    private var counts: [String: Int] = [:]
    /// The timings by name, in seconds.
    private var times: [String: [Double]] = [:]

    /// Adds one to the count `name`.
    internal func add(_ name: String) {
        add(name, 1)
    }

    /// Adds `amount` to the count `name`.
    internal func add(_ name: String, _ amount: Int) {
        lock.withLock { counts[name, default: 0] += amount }
    }

    /// Records one timing of `name`.
    internal func time(_ name: String, _ seconds: Double) {
        lock.withLock { times[name, default: []].append(seconds) }
    }

    /// The count `name` now.
    internal func get(_ name: String) -> Int {
        lock.withLock { counts[name] ?? 0 }
    }

    /// Prints every count, and the distribution of every timing.
    internal func report() {
        lock.withLock {
            for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
                say("COUNT \(name) = \(count)")
            }
            for (name, values) in times.sorted(by: { $0.key < $1.key }) {
                let sorted = values.sorted()
                let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
                let format = "TIME %@: n=%d min=%.1fms median=%.1fms p95=%.1fms max=%.1fms"
                say(
                    String(
                        format: format,
                        name,
                        sorted.count,
                        sorted[0] * 1_000,
                        sorted[sorted.count / 2] * 1_000,
                        p95 * 1_000,
                        sorted[sorted.count - 1] * 1_000
                    )
                )
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
