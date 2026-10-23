import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The pager asked for a place while its text is still being indexed, when the index is finished
/// between the look-up and its answer.
@MainActor
@Suite(.serialized)
internal struct CovViewPagerRevealTests {
    /// Ten megabytes of short lines; reads from five megabytes on wait while held.
    private static func heldText() -> CoverageViewerHeldSource {
        let line = Data((String(repeating: "word ", count: 15) + "\n").utf8)
        var big = Data()
        while big.count < 10 << 20 {
            big.append(line)
        }
        let source = CoverageViewerHeldSource(big)
        source.hold(from: 5 << 20)
        return source
    }

    /// A place that was not indexed when it was looked up, whose answer comes after the index was
    /// finished, is looked up again and reached; it is not dropped as beyond the text.
    @Test
    internal func aPlaceAnsweredAfterTheIndexWasFinishedIsLookedUpAgain() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let source = Self.heldText()
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: CoverageViewerPagerBench.wrapped,
            reusing: nil
        )
        pager.show(document, parallel: false)
        #expect(await bench.wait { pager.document === document && pager.position != nil })
        #expect(!document.isIndexComplete)
        pager.reveal(offset: 9 << 20)
        // The look-up finds the place not indexed yet; its answer waits for the main thread.
        pager.queues.lookups.sync {
            // Everything handed to the queue before has run.
        }
        // The index is finished meanwhile, on its own threads, while the main thread does not run.
        source.release()
        #expect(Wait.until { document.isIndexComplete })
        // The answer that came too early asks again, now for good.
        #expect(await bench.wait { (pager.position?.offset ?? 0) > 8 << 20 })
        #expect(!pager.isIndexing)
    }
}
