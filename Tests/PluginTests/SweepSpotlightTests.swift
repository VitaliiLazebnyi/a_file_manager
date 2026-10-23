import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// A Spotlight answer that is read after its question was stopped.
@MainActor
@Suite
internal struct SweepSpotlightTests {
    /// An answer read after the question was stopped is given to nobody.
    @Test
    internal func anAnswerReadAfterTheStopIsGivenToNobody() async {
        // The answer is read on this queue, which waits until the question was stopped.
        let queue = OperationQueue()
        queue.isSuspended = true
        let search = SpotlightSearch(
            "kMDItemFSName == \"Calculator.app\"",
            scopes: [URL(fileURLWithPath: "/System/Applications")],
            limit: SpotlightSearch.resultLimit,
            queue: queue
        )
        var answers = 0
        search.start { _, _ in answers += 1 }
        // Started again, the question is answered with what there is: read on the queue.
        search.start { _, _ in answers += 1 }
        search.stop()
        queue.isSuspended = false
        #expect(await AppWait.until { queue.operationCount == 0 })
        var later = false
        DispatchQueue.main.async { later = true }
        #expect(await AppWait.until { later })
        #expect(answers == 0)
    }
}
