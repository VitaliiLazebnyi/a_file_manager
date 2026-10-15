import AFMKernel
import AppKit
import Foundation
import Testing

@testable import ViewerPlugin

/// The pager at its edges: the scrollers, rows that are not read yet, wrapped rows and pairs
/// of units, selections begun without an anchor, and a pager that is gone.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPagerEdgeTests {
    private static let lines = (1...60).map { "Line \($0 < 10 ? "0" : "")\($0) alpha beta gamma\n" }.joined()

    private static func scrollers(_ pager: TextPagerView) -> (vertical: NSScroller, horizontal: NSScroller)? {
        let all = pager.subviews.compactMap { $0 as? NSScroller }
        guard all.count == 2 else {
            return nil
        }
        return all[0].frame.height > all[0].frame.width ? (all[0], all[1]) : (all[1], all[0])
    }

    /// A text that is gone before its rows are known is all shown; a pager takes the keyboard;
    /// selecting all of nothing selects nothing; dragging over nothing does nothing.
    @Test
    internal func edgesOfNothing() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(pager.acceptsFirstResponder)
        pager.mouseDragged(with: try #require(bench.mouse(.leftMouseDragged, row: 0, column: 0, clicks: 1, flags: [])))
        let empty = bench.document("", CoverageViewerPagerBench.wrapped)
        pager.show(empty, parallel: false)
        #expect(await bench.wait { pager.document === empty })
        pager.selectAll()
        #expect(pager.selection == nil)
        let gone = TextDocument(
            source: CoverageViewerShortSource(length: 100, available: 0),
            encoding: .utf8,
            layout: CoverageViewerPagerBench.wrapped
        )
        pager.show(gone, parallel: false)
        #expect(await bench.wait { pager.document === gone && !pager.isIndexing })
        #expect(pager.percent == 100)
    }

    /// The scrollers move the text: dragged to the end, and sideways once a long row was drawn.
    @Test
    internal func theScrollersMoveTheText() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let long = String(repeating: "wide ", count: 100) + "\n" + Self.lines
        let unwrapped = ViewerLayout.text(TextLayoutOptions(columns: 1_000, wordWrap: false))
        #expect(await bench.show(bench.document(long, unwrapped)))
        let scrollers = try #require(Self.scrollers(pager))
        scrollers.vertical.doubleValue = 1
        _ = scrollers.vertical.sendAction(scrollers.vertical.action, to: scrollers.vertical.target)
        #expect(await bench.wait { (pager.position?.line ?? 0) > 40 })
        pager.scroll(toLine: 1)
        #expect(await bench.wait { pager.position?.line == 1 })
        let rep = try #require(pager.bitmapImageRepForCachingDisplay(in: pager.bounds))
        pager.cacheDisplay(in: pager.bounds, to: rep)
        #expect(await bench.wait { scrollers.horizontal.isEnabled })
        scrollers.horizontal.doubleValue = 1
        _ = scrollers.horizontal.sendAction(scrollers.horizontal.action, to: scrollers.horizontal.target)
        #expect(scrollers.horizontal.doubleValue == 1)
        // The wheels of a mouse move it sideways too, a few characters a step.
        pager.scrollWheel(with: try CoverageViewerEvents.scroll(lines: 0, columns: 2))
        #expect(scrollers.horizontal.doubleValue < 1)
        // A trackpad's pinch with Control zooms once it adds up to a step.
        var zooms: [Int] = []
        pager.onZoom = { zooms.append($0) }
        pager.scrollWheel(with: try CoverageViewerEvents.preciseScroll(vertical: 30, flags: .maskControl))
        #expect(zooms == [1])
    }

    /// A click in the track of the scroller moves the text by a page.
    @Test
    internal func aClickInTheTrackMovesAPage() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        pager.showsCaret = false
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        pager.scrollerMoved(.incrementPage)
        #expect(await bench.wait { (pager.position?.line ?? 0) > 5 })
        let lower = try #require(pager.position).line
        pager.scrollerMoved(.decrementPage)
        #expect(await bench.wait { (pager.position?.line ?? 0) < lower })
    }

    /// Rows that come back after the reading was stopped are not shown.
    @Test
    internal func rowsOfAStoppedReadAreNotShown() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let source = CoverageViewerHeldSource(Self.lines)
        let first = TextDocument(source: source, encoding: .utf8, layout: CoverageViewerPagerBench.wrapped)
        #expect(await bench.show(first))
        source.hold()
        let second = TextDocument(
            source: source,
            encoding: .utf8,
            layout: CoverageViewerPagerBench.wrapped,
            reusing: first
        )
        pager.show(second, parallel: false)
        #expect(await bench.wait { pager.document === second && source.waitingReads >= 1 })
        pager.stopReading()
        source.release()
        await bench.settle()
        #expect(pager.position == nil)
    }

    /// Keys and clicks that come before the rows are read wait for them, or do nothing.
    @Test
    internal func keysBeforeTheRowsAreReadWaitForThem() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let source = CoverageViewerHeldSource(Self.lines)
        let first = TextDocument(source: source, encoding: .utf8, layout: CoverageViewerPagerBench.wrapped)
        #expect(await bench.show(first))
        source.hold()
        let second = TextDocument(
            source: source,
            encoding: .utf8,
            layout: CoverageViewerPagerBench.wrapped,
            reusing: first
        )
        pager.show(second, parallel: false)
        #expect(await bench.wait { pager.document === second })
        pager.mouseDown(with: try #require(bench.mouse(.leftMouseDown, row: 0, column: 3, clicks: 1, flags: [])))
        pager.mouseDragged(with: try #require(bench.mouse(.leftMouseDragged, row: 0, column: 5, clicks: 1, flags: [])))
        #expect(pager.selection == nil && pager.position == nil)
        pager.perform(.right)
        source.release()
        #expect(await bench.wait { pager.position?.offset == 1 })
    }

    /// Left at the start of a wrapped row steps onto the last character of the row before; the
    /// two halves of a pair are one step.
    @Test
    internal func wrappedRowsAndPairsAreSteppedOver() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(await bench.show(bench.document(String(repeating: "x", count: 100), CoverageViewerPagerBench.wrapped)))
        pager.perform(.down)
        pager.perform(.rowStart)
        #expect(await bench.wait { pager.position?.offset == 40 })
        pager.perform(.left)
        #expect(await bench.wait { pager.position?.offset == 39 })
        #expect(await bench.show(bench.document("a😀b\n", CoverageViewerPagerBench.wrapped)))
        pager.perform(.right)
        pager.perform(.right)
        #expect(await bench.wait { pager.position?.offset == 5 })
        pager.perform(.left)
        #expect(await bench.wait { pager.position?.offset == 1 })
    }

    /// A selection begun without an anchor starts at the cursor, or where the key put it.
    @Test
    internal func aSelectionStartsAtTheCursor() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        pager.perform(.right, extending: true)
        #expect(await bench.wait { pager.selection == nil && pager.position?.offset == 1 })
        pager.reveal(offset: 3)
        #expect(await bench.wait { pager.position?.offset == 3 })
        pager.perform(.right, extending: true)
        #expect(await bench.wait { pager.selection == 3..<4 })
    }

    /// A cursor that is looked for after its pager is gone is not looked for any further.
    @Test
    internal func aPagerThatIsGoneIsNotUpdated() async {
        let source = CoverageViewerHeldSource(Self.lines)
        weak var gone: TextPagerView?
        do {
            let bench = CoverageViewerPagerBench(width: 400, height: 200)
            let first = TextDocument(source: source, encoding: .utf8, layout: CoverageViewerPagerBench.wrapped)
            #expect(await bench.show(first))
            bench.pager.perform(.right)
            #expect(await bench.wait { bench.pager.position?.offset == 1 })
            source.hold()
            let second = TextDocument(
                source: source,
                encoding: .utf8,
                layout: CoverageViewerPagerBench.wrapped,
                reusing: first
            )
            bench.pager.show(second, at: 0, keepingSelection: true, parallel: false)
            #expect(await bench.wait { source.waitingReads >= 1 })
            gone = bench.pager
            bench.window.contentView = nil
            bench.window.close()
        }
        #expect(await CoverageViewerPagerBench.waitAlone { gone == nil })
        source.release()
        await CoverageViewerPagerBench.settleAlone()
        #expect(gone == nil)
    }
}
