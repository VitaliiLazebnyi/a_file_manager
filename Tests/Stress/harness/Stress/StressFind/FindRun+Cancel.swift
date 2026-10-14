internal import AFMKernel
internal import Foundation
internal import StressKit

@testable internal import FindFilesPlugin

/// Searches through the window cancelled at random moments.
extension FindRun {
    /// The cancel torture: `cancels` searches, each cancelled anywhere from at once to a little past
    /// its usual end.
    internal func cancelledWindowRuns() {
        var stats = CancelStats()
        let phase = "window: \(cancels) searches cancelled at random"
        step(phase, limit: Double(cancels) * 30 + 60) {
            for round in 0..<cancels {
                cancelRound(round, phase: phase, stats: &stats)
                // The next search starts right away half of the time, as a user retyping would.
                if random.next().isMultiple(of: 2) {
                    pump(for: 0.02)
                }
                stats.threadsAfter.append(threadCount())
            }
        }
        let sorted = stats.latencies.sorted()
        guard let worst = sorted.last else {
            return
        }
        say(
            String(
                format: "cancel -> finished: n=%d median=%.1fms p95=%.1fms max=%.1fms (%@); %d ended before the cancel",
                sorted.count,
                sorted[sorted.count / 2] * 1_000,
                sorted[Int(Double(sorted.count) * 0.95)] * 1_000,
                worst * 1_000,
                stats.worstLabel,
                stats.completedInstead
            )
        )
        let threads = stats.threadsAfter
        say(
            "threads right after each round: min \(threads.min() ?? 0) max \(threads.max() ?? 0) "
                + "last \(threads.last ?? 0)"
        )
    }

    /// One round of the torture: starts a random case and cancels it unless it ends first.
    private func cancelRound(_ round: Int, phase: String, stats: inout CancelStats) {
        let test = cases[Int(random.next() % UInt64(cases.count))]
        let usual = typical[test.label] ?? 1
        // Anywhere from at once to a little past the usual end.
        let delay = Double(random.next() % 1_000) / 1_000 * usual * 1.1
        let before = finishedCount
        startThroughWindow(test)
        pump(upTo: delay) { finishedCount > before }
        if finishedCount > before {
            stats.completedInstead += 1
            defer { MainWatchdog.shared.setPhase(phase) }
            verify("uncancelled in torture: " + test.label, window.resultItems, against: test.expected, filesOnly: true)
            return
        }
        let asked = now()
        window.cancelSearch()
        if !pump(upTo: 30, until: { finishedCount > before }) {
            fail("round \(round) \(test.label): a cancelled search did not end within 30 s (cancelled after \(delay)s)")
            HangGuard.shared.arm("cancelled search does not end", seconds: 0)
            pump(for: 600)
        }
        let latency = now() - asked
        stats.latencies.append(latency)
        if latency > stats.worstLatency {
            stats.worstLatency = latency
            stats.worstLabel = String(format: "%@ cancelled after %.3fs", test.label, delay)
        }
        // What a cancelled search shows must still be a duplicate-free part of the truth.
        MainWatchdog.shared.setPhase("(harness: checking results)")
        defer { MainWatchdog.shared.setPhase(phase) }
        let paths = window.resultItems.filter { !$0.isDirectory }.map(\.url.path)
        if Set(paths).count != paths.count {
            fail("round \(round) \(test.label): duplicates in a cancelled search's results")
        }
        if !Set(paths).isSubset(of: test.expected) {
            fail("round \(round) \(test.label): a cancelled search lists files that do not match")
        }
    }
}
