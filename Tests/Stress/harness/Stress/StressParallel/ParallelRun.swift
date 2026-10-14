internal import AFMKernel
internal import Dispatch
internal import Foundation
internal import StressKit

/// The whole Parallel.map torture: the numbered steps, their checks and the failures they found.
@MainActor
internal final class ParallelRun {
    /// Where samples of hung children go.
    internal let resultsDirectory: String
    /// What failed, in order.
    internal private(set) var failures: [String] = []
    /// The thread count while idle, before the first step.
    internal private(set) var baseline = 0

    /// A run that writes samples to `resultsDirectory`.
    internal init(resultsDirectory: String) {
        self.resultsDirectory = resultsDirectory
    }

    /// Runs every step and prints the report; true when nothing failed.
    internal func runAll() -> Bool {
        MainWatchdog.shared.start()
        baseline = step("0 idle baseline (1 s)") {
            pump(for: 1)
            return threadCount()
        }
        say("   threads by name at baseline: " + threadNames())
        say("cores=\(ProcessInfo.processInfo.activeProcessorCount) baseline threads=\(baseline)")
        smallMaps()
        nested()
        nestedRoots()
        nestedOnMain()
        sleepingBodies()
        bursts()
        threadsReturn()
        mainThreadRule()
        // What happens when the rule is broken, in child processes: these two are expected to hang and to
        // stop with a trap (release builds have no assertion); they are reported, not counted as failures.
        MainWatchdog.shared.setPhase("8 child cases")
        ChildCases.watch("main-in-map-bodies-sync-to-main", patience: 8, resultsDirectory: resultsDirectory)
        ChildCases.watch("main-in-map-all-bodies-sync-to-main", patience: 8, resultsDirectory: resultsDirectory)

        say("threads at the end (about 10 s later): \(threadCount()): " + threadNames())
        MainWatchdog.shared.report(title: "Parallel.map torture")
        say("\nFAILURES: \(failures.count)")
        for failure in failures {
            say("  - " + failure)
        }
        say(String(format: "peakRSS=%.0fMB", peakRSSMB()))
        return failures.isEmpty
    }

    /// Records `what` as a failure unless `passed`.
    internal func check(_ passed: Bool, _ what: String) {
        if !passed {
            failures.append(what)
            say("FAIL: " + what)
        }
    }

    /// Runs `body` on a background thread while the main thread pumps its run loop; false on timeout.
    internal func inBackground(upTo seconds: Double, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var finished = false
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        return pump(upTo: seconds) {
            if !finished, done.wait(timeout: .now()) == .success {
                finished = true
            }
            return finished
        }
    }

    /// 1. 10,000 small maps from 32 threads at once.
    private func smallMaps() {
        step("1 10,000 small maps from 32 threads", limit: 120) {
            let peak = ThreadPeak()
            let wrong = ManagedAtomicCounter()
            let finished = inBackground(upTo: 110) {
                let group = DispatchGroup()
                for thread in 0..<32 {
                    group.enter()
                    let worker = Thread {
                        ParallelWork.smallMapsOfOneThread(thread, wrong: wrong)
                        group.leave()
                    }
                    worker.start()
                }
                group.wait()
            }
            check(finished, "1: 10,016 small maps did not finish in 110 s")
            check(wrong.isZero, "1: \(wrong.count) maps returned wrong or misordered results")
            say(
                "   maps=10016 wrong=\(wrong.count) peak threads=\(peak.stop()) "
                    + "(32 callers + pool limit \(15 * 4) + harness)"
            )
        }
    }

    deinit {
        // Nothing to release.
    }
}
