import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// At most so many index builds in flight (V024): the work gate runs few jobs at once, drops what was
/// cancelled before its turn and refuses new work while too many cancelled jobs are stuck.
extension Review2PluginsBP2ViewerTests {
    /// Unchecked: the state is guarded by `condition`.
    private final class Latch: @unchecked Sendable {
        private let condition = NSCondition()
        private var open = false
        private var started: [Int] = []

        var startedJobs: [Int] {
            condition.lock()
            defer { condition.unlock() }
            return started.sorted()
        }

        func wait() {
            condition.lock()
            while !open { condition.wait() }
            condition.unlock()
        }

        func release() {
            condition.lock()
            open = true
            condition.broadcast()
            condition.unlock()
        }

        func started(_ number: Int) {
            condition.lock()
            started.append(number)
            condition.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Waits on this thread until `condition` holds or `seconds` have gone by; returns whether it holds.
    private func wait(_ seconds: Double = Wait.ceiling, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        return condition()
    }

    /// The gate runs no more jobs at once than its limit, and a job cancelled before its turn never runs.
    @Test
    internal func theGateRunsFewJobsAtOnceAndDropsWhatWasCancelledBeforeItsTurn() {
        let gate = ViewerWorkGate(live: 2, stuck: 4)
        let latch = Latch()
        let flags = (1...5).map { _ in CancellationFlag() }
        for (index, flag) in flags.enumerated() {
            gate.submit(
                cancellation: flag,
                refused: { Issue.record("Job \(index + 1) was refused") },
                {
                    latch.started(index + 1)
                    latch.wait()
                }
            )
        }
        #expect(wait { latch.startedJobs.count == 2 })
        #expect(latch.startedJobs == [1, 2] && gate.threadsInUse == 2 && gate.waitingCount == 3)
        // Job 3 is given up before its turn: it never runs.
        flags[2].cancel()
        #expect(gate.waitingCount == 2)
        // Job 1 is cancelled while it runs (stuck in a read): it holds its thread but no longer counts,
        // so job 4 starts.
        flags[0].cancel()
        #expect(wait { latch.startedJobs.contains(4) })
        #expect(gate.threadsInUse == 3)
        latch.release()
        #expect(wait { gate.threadsInUse == 0 })
        #expect(latch.startedJobs == [1, 2, 4, 5])
    }

    /// While as many cancelled jobs are stuck as the gate allows, a new job is refused; once their
    /// threads are back, jobs run again.
    @Test
    internal func whenTooManyCancelledJobsAreStuckANewOneIsRefused() {
        let gate = ViewerWorkGate(live: 1, stuck: 2)
        let latch = Latch()
        var flags: [CancellationFlag] = []
        for number in 1...2 {
            let flag = CancellationFlag()
            flags.append(flag)
            gate.submit(
                cancellation: flag,
                refused: { Issue.record("Job \(number) was refused") },
                {
                    latch.started(number)
                    latch.wait()
                }
            )
            #expect(wait { latch.startedJobs.contains(number) })
            // Cancelled, and still inside its read.
            flag.cancel()
        }
        let refused = Locked(false)
        let ran = Locked(false)
        gate.submit(
            cancellation: CancellationFlag(),
            refused: { refused.withValue { $0 = true } },
            { ran.withValue { $0 = true } }
        )
        #expect(refused.withValue { $0 } && !ran.withValue { $0 })
        #expect(gate.threadsInUse == 2)
        latch.release()
        #expect(wait { gate.threadsInUse == 0 })
        // With the threads back, a job runs again.
        let again = Latch()
        gate.submit(
            cancellation: CancellationFlag(),
            refused: { Issue.record("The job was refused") },
            { again.started(1) }
        )
        #expect(wait { again.startedJobs == [1] })
    }

    /// The gate shared by the index builds lets a few run and allows at least as many stuck ones.
    @Test
    internal func theSharedGateIsBoundedAndNeverBlocksItsCaller() {
        let gate = ViewerWorkGate.indexBuilds
        #expect(gate.live >= 2 && gate.live <= 4 && gate.stuck >= gate.live)
    }
}
