import Foundation

/// What one run of a benchmark took.
///
/// Time on the clock, processor time of all threads, and the highest memory footprint of the
/// process. Also the shape of a limit.
internal struct Measurement: Codable, Equatable {
    /// Seconds on the clock.
    internal var wallSeconds: Double
    /// Seconds of processor time, all threads together: steadier than the clock on a busy
    /// machine, and what work that is spread over the cores costs.
    internal var cpuSeconds: Double
    /// The highest footprint of the process, in megabytes (what was prepared included).
    internal var peakMegabytes: Double

    /// The median of each figure of several runs (of an even number, the higher middle one).
    internal static func median(_ runs: [Self]) -> Self {
        func middle(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        return Self(
            wallSeconds: middle(runs.map(\.wallSeconds)),
            cpuSeconds: middle(runs.map(\.cpuSeconds)),
            peakMegabytes: middle(runs.map(\.peakMegabytes))
        )
    }

    /// The lower of each figure of two measurements.
    internal func lower(_ other: Self) -> Self {
        Self(
            wallSeconds: min(wallSeconds, other.wallSeconds),
            cpuSeconds: min(cpuSeconds, other.cpuSeconds),
            peakMegabytes: min(peakMegabytes, other.peakMegabytes)
        )
    }

    /// A limit for this measurement: the figures with the margins of `Limits` added, rounded up
    /// to two significant digits so that the file stays readable.
    internal func limit() -> Self {
        func rounded(_ value: Double) -> Double {
            guard value > 0 else {
                return 0
            }
            let scale = pow(10, floor(log10(value)) - 1)
            return (value / scale).rounded(.up) * scale
        }
        return Self(
            wallSeconds: rounded(wallSeconds * Limits.wallMargin + Limits.wallAllowance),
            cpuSeconds: rounded(cpuSeconds * Limits.cpuMargin + Limits.wallAllowance),
            peakMegabytes: rounded(peakMegabytes * Limits.memoryMargin + Limits.memoryAllowance)
        )
    }

    /// The figures of this measurement that are above `limit`, as text; empty when none is.
    internal func excesses(over limit: Self) -> [String] {
        var excesses: [String] = []
        if wallSeconds > limit.wallSeconds {
            excesses.append(String(format: "time %.3f s > %.3f s", wallSeconds, limit.wallSeconds))
        }
        if cpuSeconds > limit.cpuSeconds {
            excesses.append(String(format: "processor time %.3f s > %.3f s", cpuSeconds, limit.cpuSeconds))
        }
        if peakMegabytes > limit.peakMegabytes {
            excesses.append(String(format: "memory %.0f MB > %.0f MB", peakMegabytes, limit.peakMegabytes))
        }
        return excesses
    }
}
