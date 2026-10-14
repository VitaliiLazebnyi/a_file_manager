internal import AFMKernel
internal import Darwin
internal import Dispatch
internal import Foundation
internal import StressKit

/// Steps 6 to 7b: the pool's threads come and go, and the main-thread rule.
extension ParallelRun {
    /// 6. Bursts separated by the pool's idle time (2 s), so helper threads leave while new jobs open.
    internal func bursts() {
        step("6 bursts around the 2 s thread retirement", limit: 180) {
            let wrongCount = ManagedAtomicCounter()
            let finished = inBackground(upTo: 170) {
                var random = Random(seed: 99)
                for _ in 0..<12 {
                    ParallelWork.burst(wrong: wrongCount)
                    // Sleep to just around the moment the helpers give up waiting.
                    usleep(useconds_t(1_990_000 + Int.random(in: 0...20_000, using: &random)))
                }
            }
            check(finished, "6: bursts around thread retirement did not finish (lost wakeup?)")
            check(wrongCount.isZero, "6: \(wrongCount.count) wrong results")
        }
    }

    /// 7. The pool's threads are gone a while after the last map.
    internal func threadsReturn() {
        let after = step("7 threads return to baseline (wait up to 8 s)") {
            waitForThreads(atMost: baseline + 2, upTo: 8)
        }
        say("threads: baseline=\(baseline) after=\(after)")
        say("   threads by name after the wait: " + threadNames())
        // The system's own queue threads ("unnamed") come and go by two or three at any time, so the count
        // alone is no test; what must be gone are the pool's working threads (its one watcher may stay).
        let poolThreads = threadCount(named: "AFM.Parallel", except: ".watch")
        check(poolThreads == 0, "7: \(poolThreads) threads of the pool are still there 8 s after the last map")
        check(after <= baseline + 6, "7: thread count did not return to baseline: \(baseline) -> \(after)")
    }

    /// Step 7b, the rule itself (K044): work inside a map that the main thread waits for must not wait for the
    /// main thread, and can find out that it is in that position before it tries.
    internal func mainThreadRule() {
        step("7b the main-thread rule can be asked") {
            let outside = Parallel.isHoldingUpMainThread
            // Bodies that take a while, so that helper threads take pieces too.
            let inside = Parallel.map(Array(0..<256)) { (_: Int) -> (flag: Bool, onMain: Bool) in
                usleep(2_000)
                return (Parallel.isHoldingUpMainThread, Thread.isMainThread)
            }
            let helpers = inside.filter { !$0.onMain }
            let fromBackground = ParallelWork.flagsOfABackgroundMap()
            let afterwards = Parallel.isHoldingUpMainThread
            say(
                "   flag outside any map on main: \(outside); inside a map called on main: true in "
                    + "\(inside.filter(\.flag).count) of \(inside.count) bodies "
                    + "(\(helpers.count) ran on helper threads, true in \(helpers.filter(\.flag).count)); "
                    + "in a map called on a background thread: true in \(fromBackground.filter(\.self).count) "
                    + "of \(fromBackground.count); after: \(afterwards)"
            )
            check(!outside && !afterwards, "7b: isHoldingUpMainThread is true on the main thread outside a map")
            check(
                inside.allSatisfy(\.flag),
                "7b: a body of a map called on the main thread was not told that it holds up the main thread"
            )
            check(!helpers.isEmpty, "7b: no body ran on a helper thread, so the rule was not tried there")
            check(
                !fromBackground.contains(true),
                "7b: a map called on a background thread says it holds up the main thread"
            )
        }
    }
}
