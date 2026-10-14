internal import AFMKernel
internal import Dispatch
internal import Foundation
internal import StressKit
internal import TestSupport

/// The work of the steps that runs on threads of its own, away from the main thread.
internal enum ParallelWork {
    /// The 313 small maps of one of the 32 calling threads of step 1.
    internal static func smallMapsOfOneThread(_ thread: Int, wrong: ManagedAtomicCounter) {
        var random = Random(seed: UInt64(thread))
        for round in 0..<313 {
            let count = Int.random(in: 2...64, using: &random)
            let seed = thread * 1_000 + round
            let input = (0..<count).map { $0 &+ seed }
            let output = Parallel.map(input) { $0 &* 3 &+ 1 }
            if output != input.map({ $0 &* 3 &+ 1 }) {
                wrong.add()
            }
        }
    }

    /// Starts the four root threads of step 3; each stores its tree's sum in `results` and then
    /// counts itself in `finished`.
    internal static func startRoots(results: Shared<[UInt64]>, finished: Shared<Int>) {
        for root in 0..<4 {
            let thread = Thread {
                let behaviour = Behaviour(sleeps: true, callsStat: true, mainSync: true)
                let value = NestedTree.tree(depth: 4, width: 16, path: UInt64(root + 1), behaviour)
                results.modify { $0[root] = value }
                finished.modify { $0 += 1 }
            }
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    /// One burst of step 6: 8 threads, each 50 maps; counts the wrong results.
    internal static func burst(wrong: ManagedAtomicCounter) {
        let group = DispatchGroup()
        for caller in 0..<8 {
            group.enter()
            let thread = Thread {
                for inner in 0..<50 {
                    let input = Array(0..<(40 + inner))
                    if Parallel.map(input, { $0 + caller }) != input.map({ $0 + caller }) {
                        wrong.add()
                    }
                }
                group.leave()
            }
            thread.start()
        }
        group.wait()
    }

    /// What `isHoldingUpMainThread` says in the bodies of a map called on a background thread
    /// (the caller waits without pumping).
    internal static func flagsOfABackgroundMap() -> [Bool] {
        let flags = Shared<[Bool]>([])
        let done = DispatchSemaphore(value: 0)
        Thread {
            flags.value = Parallel.map(Array(0..<256)) { (_: Int) -> Bool in
                usleep(500)
                return Parallel.isHoldingUpMainThread
            }
            done.signal()
        }
        .start()
        done.wait()
        return flags.value
    }
}
