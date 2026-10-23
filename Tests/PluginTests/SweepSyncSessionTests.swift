import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// A plan of Synchronize directories that is made after its session went.
@MainActor
@Suite
internal struct SweepSyncSessionTests {
    /// A plan that is ready when its session is gone asks nothing.
    @Test
    internal func aPlanReadyAfterItsSessionWentAsksNothing() async {
        let memory = MemoryFileSystem()
        memory.addFile("/A/new.txt", "from the left")
        memory.addFile("/B/old.txt", "from the right")
        let bench = TestBench(
            plugins: [DirectorySyncPlugin(opensWindows: false)],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        bench.interaction.formAnswers = [.cancel]
        var work: [@Sendable () -> Void] = []
        weak var gone: SyncSession?
        do {
            let session = SyncSession(kernel: bench.kernel)
            session.runsInline = true
            session.adopt(
                left: bench.left.model,
                right: bench.right.model,
                includeHidden: false,
                readsInBackgroundFrom: SyncSession.backgroundFrom
            )
            session.compare()
            #expect(session.canSynchronize)
            session.runsInline = false
            session.worksInBackgroundFrom = 1
            session.startWorker = { _, body in work.append(body) }
            session.synchronize()
            #expect(session.status == "Preparing the plan…" && work.count == 1)
            gone = session
        }
        #expect(gone == nil)
        // The plan is made now, and handed to the main thread, where nobody waits for it.
        for body in work { body() }
        var later = false
        DispatchQueue.main.async { later = true }
        #expect(await AppWait.until { later })
        #expect(!bench.interaction.log.contains { $0.hasPrefix("form:") })
    }
}
