import AFMKernel
import Foundation
import TestSupport
import Testing

/// Work spread over threads, the flag that stops it, and how its progress is told.
@Suite
internal struct ConcurrencyTests {
    /// The results come in the order of the input, for long, empty, single and short serial inputs.
    @Test
    internal func parallelMapKeepsTheOrder() {
        let input = Array(0..<10_000)
        #expect(Parallel.map(input) { $0 * 2 } == input.map { $0 * 2 })
        #expect(Parallel.map([Int]()) { $0 }.isEmpty)
        #expect(Parallel.map([7]) { "\($0)" } == ["7"])
        #expect(Parallel.map(Array(0..<10), serialBelow: 100) { $0 + 1 } == Array(1...10))
    }

    /// On a machine of more than one core, the pieces of one call run on more than one thread.
    @Test
    internal func parallelMapUsesSeveralThreads() {
        let threads = Shared(Set<UInt64>())
        let isSingleCore = ProcessInfo.processInfo.activeProcessorCount == 1
        // The threads are shared with whatever else runs at the time (other tests keep them
        // busy, and the oldest job is served first), so a second one is waited for: a
        // condition, with a ceiling only a hang reaches.
        _ = Parallel.map(Array(0..<64)) { _ -> Bool in
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            threads.modify { $0.insert(id) }
            return isSingleCore || Wait.until(seconds: 30) { threads.value.count > 1 }
        }
        #expect(threads.value.count > 1 || isSingleCore)
    }

    /// A flag set on one thread is seen by every other.
    @Test
    internal func aCancellationFlagIsSeenFromEveryThread() {
        let flag = CancellationFlag()
        #expect(!flag.isCancelled)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            if index == 3 {
                flag.cancel()
            }
            _ = flag.isCancelled
        }
        #expect(flag.isCancelled)
    }

    /// Progress is measured in bytes when they are known, in items otherwise.
    @Test
    internal func jobProgressChoosesBytesOrItems() {
        let copying = JobProgress(
            lines: ["From: a", "To: b"],
            itemsDone: 1,
            itemsTotal: 4,
            bytesDone: 250,
            bytesTotal: 1_000
        )
        #expect(copying.measuresBytes && copying.amountDone == 250)
        #expect(copying.amountTotal == 1_000 && copying.fraction == 0.25)
        let deleting = JobProgress(lines: ["Deleting: a"], itemsDone: 1, itemsTotal: 4)
        #expect(!deleting.measuresBytes && deleting.amountDone == 1)
        #expect(deleting.amountTotal == 4 && deleting.fraction == 0.25)
    }
}
