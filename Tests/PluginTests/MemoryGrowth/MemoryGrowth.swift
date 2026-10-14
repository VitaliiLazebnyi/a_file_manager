import Darwin
import Foundation
import TestSupport

/// Measures whether doing something again and again makes the process hold more memory.
///
/// The work is done in rounds: one round to warm up (caches fill, pools reach their size), then
/// several measured ones. After each round the freed memory is handed back to the system and the
/// footprint is read. Memory that is released settles at one level; memory that is kept (a leak, a
/// cache without a bound, a cycle) rises with every round. The work does not grow when the last
/// round ends no more than `tolerance` above the first measured one.
///
/// The footprint is the whole process's, so these tests run on their own, one after another
/// (`Scripts/check.sh memory` sets `AFM_MEMORY_GROWTH=1` and runs only them); in the ordinary test
/// run they are skipped.
internal enum MemoryGrowth {
    /// Whether the memory tests run (they measure the whole process, so not beside other tests).
    internal static let isEnabled = ProcessInfo.processInfo.environment["AFM_MEMORY_GROWTH"] == "1"

    /// Measured rounds after the warm-up.
    internal static let rounds = 5

    /// The footprint once freed memory has been handed back.
    internal static func settledFootprint() -> Int {
        malloc_zone_pressure_relief(nil, 0)
        return Footprint.current
    }

    /// The footprints after each measured round of `perRound` runs of `work`.
    @MainActor
    internal static func footprints(perRound: Int, _ work: @MainActor () throws -> Void) rethrows -> [Int] {
        var footprints: [Int] = []
        for round in 0...rounds {
            for _ in 0..<perRound {
                try autoreleasepool(invoking: work)
            }
            if round > 0 {
                footprints.append(settledFootprint())
            }
        }
        return footprints
    }

    /// The same for work that waits for something.
    @MainActor
    internal static func footprints(perRound: Int, _ work: @MainActor () async throws -> Void) async rethrows -> [Int] {
        var footprints: [Int] = []
        for round in 0...rounds {
            for _ in 0..<perRound {
                try await work()
            }
            if round > 0 {
                footprints.append(settledFootprint())
            }
        }
        return footprints
    }

    /// What is wrong with the footprints: nil when the last is at most `tolerance` bytes above the
    /// first, else a message with every round's figure and the growth per run.
    internal static func growth(_ footprints: [Int], perRound: Int, tolerance: Int) -> String? {
        guard let first = footprints.first, let last = footprints.last, last - first > tolerance else {
            return nil
        }
        let megabytes = footprints.map { String(format: "%.1f", Double($0) / 1_048_576) }
        let perRun = Double(last - first) / Double(perRound * (footprints.count - 1))
        return "memory grows: \(megabytes.joined(separator: " → ")) MB after rounds of \(perRound) runs, "
            + String(format: "%.0f bytes per run", perRun)
    }
}
