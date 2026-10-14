import Foundation

/// Measures how fast a job advances and estimates the time left. The speed is the average over
/// the last few seconds, so it follows changes without jumping with every block.
public struct TransferRate {
    private let window: TimeInterval
    private var samples: [(time: TimeInterval, amount: Int64)] = []

    /// The shortest span of measurements that gives a usable speed.
    public static let minimumSpan: TimeInterval = 1

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    /// Records the amount done (bytes or items) at a point in time, in seconds.
    public mutating func add(amount: Int64, at time: TimeInterval) {
        if let last = samples.last, time <= last.time {
            samples[samples.count - 1].amount = max(last.amount, amount)
            return
        }
        samples.append((time, amount))
        // Keep one sample at or before the start of the window as its left edge.
        while samples.count > 2, samples[1].time <= time - window { samples.removeFirst() }
    }

    /// Forgets the measurements, e.g. after the job waited for an answer.
    public mutating func reset() {
        samples = []
    }

    /// Amount per second; nil until enough has been measured.
    public var perSecond: Double? {
        guard let first = samples.first, let last = samples.last,
              last.time - first.time >= TransferRate.minimumSpan else { return nil }
        return Double(last.amount - first.amount) / (last.time - first.time)
    }

    /// Seconds until `total` is reached at the current speed; nil while unknown or stalled.
    public func remaining(total: Int64) -> TimeInterval? {
        guard let rate = perSecond, rate > 0, let done = samples.last?.amount else { return nil }
        return Double(max(0, total - done)) / rate
    }
}
