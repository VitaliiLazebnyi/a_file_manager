import Foundation

/// Measures how fast a job advances and estimates the time left.
///
/// The speed is the average over the last few seconds (`window`), so it follows changes without
/// jumping with every block.
internal struct TransferRate {
    /// The shortest span of measurements that gives a usable speed, in seconds.
    internal static let minimumSpan: TimeInterval = 1
    /// How far back the speed looks, in seconds.
    internal static let window: TimeInterval = 5

    /// The measurements of the window: when, and how much was done by then.
    private var samples: [(time: TimeInterval, amount: Int64)] = []

    /// Amount per second; nil until enough has been measured.
    internal var perSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= Self.minimumSpan else {
            return nil
        }
        return Double(last.amount - first.amount) / (last.time - first.time)
    }

    /// Nothing measured yet.
    internal init() {
        // The first sample starts the measuring.
    }

    /// Records the amount done (bytes or items) at a point in time, in seconds.
    ///
    /// A sample that is not later than the last one only raises its amount.
    internal mutating func add(amount: Int64, at time: TimeInterval) {
        if let last = samples.last, time <= last.time {
            samples[samples.count - 1].amount = max(last.amount, amount)
            return
        }
        samples.append((time, amount))
        // Keep one sample at or before the start of the window as its left edge.
        while samples.count > 2, samples[1].time <= time - Self.window {
            samples.removeFirst()
        }
    }

    /// Forgets the measurements, e.g. after the job waited for an answer.
    internal mutating func reset() {
        samples = []
    }

    /// Seconds until `total` is reached at the current speed; nil while unknown or stalled.
    internal func remaining(total: Int64) -> TimeInterval? {
        guard let rate = perSecond, rate > 0, let done = samples.last?.amount else {
            return nil
        }
        return Double(max(0, total - done)) / rate
    }
}
