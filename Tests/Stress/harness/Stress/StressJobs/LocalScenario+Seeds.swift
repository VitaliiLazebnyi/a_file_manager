import FileOperationsPlugin
import StressKit

/// The seeds.
extension LocalScenario {
    /// One seed: copy and delete with interference, then move with interference and back, which
    /// must restore the tree.
    internal func runSeed(_ seed: Int) {
        var random = Random(seed: UInt64(seed) &* 0x1234_5678_9ABC)
        HangGuard.shared.arm("seed \(seed)", seconds: 900)
        let tree = layout
        // Copy with interference, then delete what arrived with interference, then remove the rest.
        _ = copyRun(seed: seed, randomInterference("copy", &random))
        let deleted = deleteRun(seed: seed, randomInterference("delete", &random))
        if deleted.result.cancelled || !offMain({ Tree.topLevel(tree.destination) }).isEmpty {
            let rest = deleteRun(seed: seed + 100_000, Interference(pauses: true))
            if rest.result.cancelled {
                Findings.shared.violation("delete: uninterrupted run reports cancelled", "seed \(seed)")
            }
        }
        // Move with interference, then move everything back (pauses only), which must restore the tree.
        _ = moveRun(seed: seed, randomInterference("move", &random), back: false)
        var back = randomInterference("move-back", &random)
        _ = moveRun(seed: seed, back, back: true)
        back = Interference(pauses: seed.isMultiple(of: 2))
        let restored = moveRun(seed: seed + 100_000, back, back: true)
        if restored.result.cancelled {
            Findings.shared.violation("move-back: uninterrupted run reports cancelled", "seed \(seed)")
        }
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain { tree.verifyRestored(seed: seed) }
        let threads = threadCount()
        threadsAfter.append(threads)
        let last = settings.seedBase + settings.seedCount - 1
        if (seed - settings.seedBase + 1).isMultiple(of: 10) || seed == last {
            settle(after: seed, threadsRightAfter: threads)
        }
    }

    /// Lets the threads settle after `seed` and checks that the program's own are gone.
    private func settle(after seed: Int, threadsRightAfter threads: Int) {
        MainWatchdog.shared.setPhase("settle (idle)")
        let settled = waitForThreads(atMost: baselineThreads, upTo: 8)
        say(
            "THREADS after seed \(seed): right after=\(threads) settled(<=8s)=\(settled) baseline=\(baselineThreads) "
                + "max so far=\(maxThreads) footprint=\(Int(footprintMB()))MB peakRSS=\(Int(peakRSSMB()))MB "
                + "load=\(loadAverage())"
        )
        // (The system's queue threads come and go by a few; the program's own named threads must be gone.)
        if settled > baselineThreads + 2, threadCount(named: "AFM.", except: ".watch") > 0 {
            Findings.shared.violation(
                "threads did not return to baseline",
                "after seed \(seed): \(settled) vs \(baselineThreads): " + threadNames()
            )
        }
    }
}
