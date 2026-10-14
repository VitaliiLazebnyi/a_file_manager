internal import AFMKernel
internal import Darwin
internal import Foundation
internal import StressKit
internal import TestSupport

/// Steps 2 to 5: nested maps, maps on the main thread, bodies that only wait.
extension ParallelRun {
    /// 2. Nested maps, depth 4 x width 16, with bodies that sleep and do I/O, from a background thread.
    internal func nested() {
        let want4 = NestedTree.expected(depth: 4, width: 16, path: 1)
        step("2 nested depth 4 x width 16 (sleep, I/O)", limit: 180) {
            let peak = ThreadPeak()
            let result = Shared<UInt64>(0)
            let finished = inBackground(upTo: 170) {
                result.value = NestedTree.tree(depth: 4, width: 16, path: 1, Behaviour())
            }
            let got = result.value
            check(finished, "2: nested map did not finish in 170 s")
            check(got == want4, "2: nested map returned \(got), expected \(want4)")
            say("   leaves=65536 correct=\(got == want4) peak threads=\(peak.stop())")
        }
    }

    /// 3. The same from 4 threads at once, with bodies that also hop to the main thread, while the
    ///    main thread itself keeps calling Parallel.map between turns of its run loop.
    internal func nestedRoots() {
        step("3 nested x4 roots + main.sync hops + main in map", limit: 240) {
            let peak = ThreadPeak()
            let results = Shared([UInt64](repeating: 0, count: 4))
            let finishedRoots = Shared(0)
            ParallelWork.startRoots(results: results, finished: finishedRoots)
            var mainMaps = 0
            var mainWrong = 0
            let finished = pump(upTo: 220) {
                // The main thread's own map, between turns of the run loop.
                let input = Array(0..<200)
                let output = Parallel.map(input) { NestedTree.mix(UInt64($0)) }
                if output != input.map({ NestedTree.mix(UInt64($0)) }) {
                    mainWrong += 1
                }
                mainMaps += 1
                return finishedRoots.value == 4
            }
            check(finished, "3: nested maps with main.sync hops did not finish in 220 s (deadlock?)")
            let values = results.value
            for root in 0..<4 {
                let want = NestedTree.expected(depth: 4, width: 16, path: UInt64(root + 1))
                check(values[root] == want, "3: root \(root) returned \(values[root]), expected \(want)")
            }
            check(mainWrong == 0, "3: \(mainWrong) main-thread maps wrong")
            say(
                "   roots=4 leaves=262144 mainSync hops=\(NestedTree.mainSyncs.count) main-thread maps=\(mainMaps) "
                    + "peak threads=\(peak.stop())"
            )
        }
    }

    /// 4. Nested map called on the main thread itself (the UI thread is blocked for its length by design).
    internal func nestedOnMain() {
        step("4 nested depth 3 x 16 ON the main thread", limit: 120) {
            let got = NestedTree.tree(
                depth: 3,
                width: 16,
                path: 7,
                Behaviour(sleeps: true, callsStat: true, mainSync: false)
            )
            check(got == NestedTree.expected(depth: 3, width: 16, path: 7), "4: wrong result on main thread")
        }
    }

    /// 5. Bodies that only wait: does the pool grow, and how far.
    internal func sleepingBodies() {
        step("5 256 bodies that each sleep 100 ms", limit: 120) {
            let peak = ThreadPeak()
            let started = now()
            let out = Shared<[Int]>([])
            let finished = inBackground(upTo: 110) {
                out.value = Parallel.map(Array(0..<256)) { value in
                    usleep(100_000)
                    return value
                }
            }
            check(finished && out.value == Array(0..<256), "5: sleeping bodies wrong or late")
            say(
                String(
                    format:
                        "   wall=%.2fs (serial would be 25.6 s; 16 threads 1.6 s; 60 threads 0.43 s) peak threads=%d",
                    now() - started,
                    peak.stop()
                )
            )
        }
    }
}
