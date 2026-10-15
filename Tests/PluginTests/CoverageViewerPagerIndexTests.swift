import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The pager while texts are indexed, laid out anew and read slowly: what is kept across a new
/// layout, requests that are overtaken, refused builds and reads that fail.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPagerIndexTests {
    private static let lines = (1...60).map { "Line \($0 < 10 ? "0" : "")\($0) alpha beta gamma\n" }.joined()
    private static let rowLength = Int64(Self.lines.utf8.count / 60)

    private static func document(_ source: any ByteSource, reusing previous: TextDocument?) -> TextDocument {
        TextDocument(source: source, encoding: .utf8, layout: CoverageViewerPagerBench.wrapped, reusing: previous)
    }

    /// Holds the calling thread until `semaphore` is signalled.
    private static func block(until semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    /// A build the gate refuses shows the text as far as it is known, with the reason; a text
    /// that is replaced while it is still to be indexed stops being indexed.
    @Test
    internal func aRefusedBuildShowsWhatIsKnown() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let gate = ViewerWorkGate(live: 1, stuck: 1)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let flag = CancellationFlag()
        gate.submit(cancellation: flag) {
            started.signal()
            _ = release.wait(timeout: .now() + 60)
        }
        Self.block(until: started)
        flag.cancel()
        bench.pager.indexGate = gate
        let refused = bench.document(Self.lines, CoverageViewerPagerBench.wrapped)
        bench.pager.show(refused, parallel: false)
        #expect(await bench.wait { bench.pager.document === refused })
        #expect(refused.readError as? ViewerError == .busy && !refused.isIndexComplete)
        // The next text takes over; the refused one is told to stop.
        bench.pager.indexGate = ViewerWorkGate(live: 1, stuck: 1)
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        #expect(refused.indexCancellation.isCancelled)
        release.signal()
        #expect(await bench.wait { gate.threadsInUse == 0 })
    }

    /// Laid out anew, the text keeps its place, its selection, its cursor and a place it was on
    /// its way to.
    @Test
    internal func aNewLayoutKeepsWhatTheUserSees() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let source = CoverageViewerHeldSource(Self.lines)
        let first = Self.document(source, reusing: nil)
        #expect(await bench.show(first))
        pager.perform(.right)
        #expect(await bench.wait { pager.position?.offset == 1 })
        // The cursor is found again in the new layout.
        let second = Self.document(source, reusing: first)
        pager.show(second, at: pager.topOffset, keepingSelection: true, parallel: false)
        #expect(await bench.wait { pager.document === second && pager.position?.offset == 1 })
        // A place the view is on its way to is carried over; the old look-up comes back too late.
        source.hold()
        pager.reveal(offset: 30 * Self.rowLength)
        #expect(await bench.wait { source.waitingReads == 1 })
        let third = Self.document(source, reusing: second)
        pager.show(third, at: pager.topOffset, keepingSelection: true, parallel: false)
        #expect(await bench.wait { pager.document === third })
        source.release()
        #expect(await bench.wait { pager.position?.offset == 30 * Self.rowLength })
        // Scrolled down, the new layout keeps the top row.
        pager.scroll(toLine: 40)
        #expect(await bench.wait { pager.position?.line == 40 })
        let fourth = Self.document(source, reusing: third)
        pager.show(fourth, at: pager.topOffset, keepingSelection: true, parallel: false)
        #expect(await bench.wait { pager.document === fourth && pager.position?.line == 40 })
        // A found text is shown selected, a few rows below the top.
        let fifth = Self.document(source, reusing: fourth)
        let found = 50 * Self.rowLength..<50 * Self.rowLength + 4
        pager.show(fifth, at: found.lowerBound, select: found, parallel: false)
        #expect(await bench.wait { pager.document === fifth && pager.selection == found })
    }

    /// A cursor that cannot be found again (the reading fails, or the text is gone) is let go.
    @Test
    internal func aCursorThatCannotBeFoundIsLetGo() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let source = CoverageViewerHeldSource(Self.lines)
        let first = Self.document(source, reusing: nil)
        #expect(await bench.show(first))
        pager.scroll(toLine: 30)
        #expect(await bench.wait { pager.position?.line == 30 })
        pager.perform(.right)
        #expect(await bench.wait { pager.position?.offset == 29 * Self.rowLength + 1 })
        source.fail(true)
        let second = Self.document(source, reusing: first)
        pager.show(second, at: pager.topOffset, keepingSelection: true, parallel: false)
        #expect(await bench.wait { pager.document === second && second.readError != nil })
        source.fail(false)
        // The text is dropped while the cursor is looked for.
        source.hold()
        let third = Self.document(source, reusing: first)
        pager.show(third, at: 0, keepingSelection: true, parallel: false)
        #expect(await bench.wait { pager.document === third })
        pager.clear()
        source.release()
        await bench.settle()
        #expect(pager.document == nil)
    }

    /// Of several requests to go somewhere only the last counts, however slowly they are answered.
    @Test
    internal func onlyTheLastRequestCounts() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let source = CoverageViewerHeldSource(Self.lines)
        #expect(await bench.show(Self.document(source, reusing: nil)))
        source.hold()
        pager.reveal(offset: 10 * Self.rowLength)
        #expect(await bench.wait { source.waitingReads == 1 })
        pager.reveal(offset: 20 * Self.rowLength)
        pager.reveal(offset: 45 * Self.rowLength)
        source.release()
        #expect(await bench.wait { pager.position?.offset == 45 * Self.rowLength })
        source.hold()
        pager.scroll(toLine: 10)
        #expect(await bench.wait { source.waitingReads == 1 })
        pager.scroll(toLine: 20)
        pager.scroll(toLine: 50)
        source.release()
        #expect(await bench.wait { pager.position?.line == 50 })
    }

    /// Reads that fail leave the rows as they are and say why; a place that cannot be looked up
    /// is not waited for.
    @Test
    internal func failingReadsAreReported() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        pager.showsCaret = false
        let source = CoverageViewerHeldSource(Self.lines)
        let document = Self.document(source, reusing: nil)
        #expect(await bench.show(document))
        source.fail(true)
        pager.reveal(offset: 40 * Self.rowLength)
        pager.scroll(toLine: 45)
        pager.perform(.fileEnd)
        #expect(await bench.wait { document.readError != nil })
        await bench.settle()
        source.fail(false)
        pager.reveal(offset: 5 * Self.rowLength)
        #expect(await bench.wait { pager.position?.line == 6 })
    }

    /// A place beyond what is indexed is reached once the index gets there.
    @Test
    internal func aPlaceBeyondTheIndexIsReachedLater() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let line = Data((String(repeating: "word ", count: 15) + "\n").utf8)
        var big = Data()
        while big.count < 10 << 20 {
            big.append(line)
        }
        let source = CoverageViewerHeldSource(big)
        source.hold(from: 5 << 20)
        let document = Self.document(source, reusing: nil)
        pager.show(document, parallel: false)
        #expect(await bench.wait { pager.document === document && pager.position != nil })
        #expect(pager.isIndexing && pager.indexingProgress < 1)
        pager.reveal(offset: 9 << 20)
        pager.scroll(toPercent: 95)
        await bench.settle()
        source.release()
        #expect(await bench.wait { !pager.isIndexing && pager.position != nil })
    }
}
