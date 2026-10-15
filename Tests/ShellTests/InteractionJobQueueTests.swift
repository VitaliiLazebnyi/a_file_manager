import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The queue of jobs behind the progress window: stopping everything, jobs that do not stop,
/// and jobs handed in at the last moment.
@MainActor
@Suite(.serialized)
internal struct InteractionJobQueueTests {
    /// A job handed in while everything is being stopped is stopped as well; a completion that
    /// hands in another job keeps whoever waits for the queue waiting until that one has ended.
    @Test
    internal func aJobHandedInWhileEverythingStopsIsStoppedToo() async {
        let service = ProgressJobService()
        let reporter = InteractionProgressTests.Reporter()
        defer { reporter.end() }
        var results: [String] = []
        let late = InteractionProgressTests.Reporter()
        service.run(
            title: "First",
            work: { reporter.work($0) },
            completion: { result in
                results.append(result)
                // Handed in by the last completion, while everything is being stopped.
                service.run(title: "Late", work: { late.work($0) }, completion: { results.append($0) })
            }
        )
        #expect(await AppWait.until { reporter.count > 1 })
        var idle = false
        service.cancelAll { idle = true }
        #expect(await AppWait.until { results == ["cancelled", "cancelled"] })
        #expect(await AppWait.until { idle } && !service.isBusy)
    }

    /// A job that does not stop is asked about once however often it is told to; left behind,
    /// the queue moves on, and when it comes back at last its completion still runs.
    @Test
    internal func aJobLeftBehindStillHearsOfItsEnd() async {
        let service = ProgressJobService()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        service.patience = 0.05
        var asked: [String] = []
        service.askToAbandon = { title in
            asked.append(title)
            return true
        }
        var results: [String] = []
        service.run(title: "Stuck", work: { _ in release.wait() }, completion: { results.append("stuck back") })
        service.cancelCurrent()
        service.cancelCurrent()
        #expect(await AppWait.until { service.abandonedCount == 1 })
        #expect(asked == ["Stuck"] && !service.isBusy && results.isEmpty)
        release.signal()
        #expect(await AppWait.until { results == ["stuck back"] })
        #expect(service.abandonedCount == 0)
    }

    /// A job that ends while the user is asked about it is not left behind.
    @Test
    internal func aJobThatEndsDuringTheQuestionIsNotLeftBehind() async {
        let service = ProgressJobService()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        service.patience = 0.05
        var finished = false
        service.askToAbandon = { _ in
            // The question is on screen while the job ends (its modal loop keeps the program going).
            release.signal()
            let end = Date(timeIntervalSinceNow: Wait.ceiling)
            while !finished, Date() < end {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            }
            return true
        }
        service.run(title: "Slow", work: { _ in release.wait() }, completion: { finished = true })
        service.cancelCurrent()
        #expect(await AppWait.until { finished })
        #expect(service.abandonedCount == 0 && !service.isBusy)
    }

    /// While the program quits the question about a job is the quitting's: it is not asked here,
    /// and the job is asked about again later.
    @Test
    internal func whileQuittingTheServiceDoesNotAsk() async {
        let service = ProgressJobService()
        let release = DispatchSemaphore(value: 0)
        service.patience = 0.01
        service.isQuitting = true
        var asked = 0
        service.askToAbandon = { _ in
            asked += 1
            return true
        }
        var done = false
        service.run(title: "Stuck", work: { _ in release.wait() }, completion: { done = true })
        service.cancelCurrent()
        // Long enough for the first wait and the doubled second one.
        await AppWait.until(seconds: 0.2) { false }
        release.signal()
        #expect(await AppWait.until { done })
        #expect(asked == 0 && service.abandonedCount == 0)
    }
}
