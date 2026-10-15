import AFMKernel
import AppKit
import Foundation
import Testing

@testable import ViewerPlugin

/// The pager without a pane: its handlers, the wheel, the keys with and without the text cursor,
/// the mouse, and drawing a selection.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPagerTests {
    private static let lines = (1...60).map { "Line \($0 < 10 ? "0" : "")\($0) alpha beta_gamma délta\n" }.joined()

    /// Without a text: no position, the whole of nothing, and nothing to go to.
    @Test
    internal func anEmptyPagerHasNothingToShow() {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(pager.percent == 100 && pager.topOffset == 0 && pager.searchStart(backwards: false) == 0)
        #expect(!pager.isIndexing && pager.indexingProgress == 1 && pager.position == nil)
        pager.reveal(offset: 10)
        pager.scroll(toPercent: 50)
        pager.scroll(toLine: 3)
        pager.selectAll()
        pager.perform(.down)
        #expect(pager.selection == nil && pager.position == nil)
    }

    /// A pager nobody listens to does what it is asked all the same; it takes the keyboard.
    @Test
    internal func aPagerWithoutListenersStillWorks() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        pager.setFrameSize(NSSize(width: 380, height: 190))
        #expect(
            pager.menu(for: try #require(bench.mouse(.rightMouseDown, row: 0, column: 0, clicks: 1, flags: []))) == nil
        )
        pager.scrollWheel(with: try CoverageViewerEvents.scroll(lines: 3, flags: .maskControl))
        #expect(bench.window.makeFirstResponder(pager) && bench.window.firstResponder === pager)
        #expect(bench.window.makeFirstResponder(nil) && bench.window.firstResponder !== pager)
        pager.clearSelection()
        #expect(pager.selection == nil)
    }

    /// The wheel with Control zooms in whole steps; without it the text scrolls, sideways too.
    @Test
    internal func theWheelScrollsAndZooms() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        var zooms: [Int] = []
        pager.onZoom = { zooms.append($0) }
        let long = String(repeating: "wide ", count: 100) + "\n" + Self.lines
        let unwrapped = ViewerLayout.text(TextLayoutOptions(columns: 1_000, wordWrap: false))
        #expect(await bench.show(bench.document(long, unwrapped)))
        pager.scrollWheel(with: try CoverageViewerEvents.scroll(lines: 2, flags: .maskControl))
        pager.scrollWheel(with: try CoverageViewerEvents.scroll(lines: -9, flags: .maskControl))
        // A trackpad's small steps add up to one.
        for _ in 0..<5 {
            pager.scrollWheel(with: try CoverageViewerEvents.preciseScroll(vertical: 10, horizontal: 0))
        }
        #expect(zooms == [2, -3])
        let top = try #require(pager.position).line
        pager.scrollWheel(with: try CoverageViewerEvents.scroll(lines: -3, flags: []))
        #expect(await bench.wait { (pager.position?.line ?? 0) > top })
        // Sideways, once the width of the long line is known from drawing it.
        _ = bench.pager.bitmapImageRepForCachingDisplay(in: pager.bounds)
            .map { pager.cacheDisplay(in: pager.bounds, to: $0) }
        await bench.settle()
        pager.scrollWheel(with: try CoverageViewerEvents.preciseScroll(vertical: 0, horizontal: -50))
        pager.scrollWheel(with: try CoverageViewerEvents.scroll(lines: 0, flags: []))
        #expect(pager.position != nil)
    }

    /// Without the text cursor the keys scroll the text.
    @Test
    internal func withoutTheCursorTheKeysScroll() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        pager.showsCaret = false
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        func line() -> Int { pager.position?.line ?? 0 }
        pager.perform(.down)
        #expect(await bench.wait { line() == 2 })
        pager.perform(.pageDown)
        #expect(await bench.wait { line() > 2 })
        pager.perform(.fileEnd)
        #expect(await bench.wait { line() > 40 })
        pager.perform(.pageUp)
        pager.perform(.up)
        pager.perform(.fileStart)
        #expect(await bench.wait { line() == 1 })
        pager.perform(.rowEnd)
        pager.perform(.rowStart)
        for motion: TextPagerView.Motion in [.right, .left, .wordRight, .wordLeft] {
            pager.perform(motion)
        }
        #expect(await bench.wait { line() == 1 } && pager.selection == nil)
    }

    /// The cursor moves by characters, words, rows and pages, and keeps its column going up
    /// and down; Shift selects.
    @Test
    internal func theCursorMovesThroughTheText() async {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        func offset() -> Int64 { pager.position?.offset ?? -1 }
        pager.perform(.right)
        #expect(await bench.wait { offset() == 1 })
        pager.perform(.wordRight)
        #expect(await bench.wait { offset() == 5 })
        pager.perform(.down)
        pager.perform(.pageDown)
        pager.perform(.pageUp)
        pager.perform(.up)
        #expect(await bench.wait { offset() == 5 })
        pager.perform(.wordLeft)
        #expect(await bench.wait { offset() == 0 })
        // At the start of a row Left goes to the end of the row above; at the very start nowhere.
        pager.perform(.left)
        #expect(await bench.wait { offset() == 0 })
        pager.perform(.down)
        pager.perform(.rowStart)
        let second = offset()
        pager.perform(.left)
        #expect(await bench.wait { offset() == second - 1 })
        pager.perform(.rowEnd)
        pager.perform(.right)
        #expect(await bench.wait { offset() == second })
        pager.perform(.right, extending: true)
        #expect(await bench.wait { pager.selection == second..<second + 1 })
        pager.perform(.left, extending: true)
        #expect(await bench.wait { pager.selection == nil })
        // At the end of the text Right goes nowhere.
        let end = Int64(Self.lines.utf8.count)
        pager.perform(.fileEnd)
        #expect(await bench.wait { offset() >= end - 1 })
        let last = offset()
        pager.perform(.right)
        await bench.settle()
        #expect(offset() == last)
    }

    /// In hex the cursor goes byte by byte.
    @Test
    internal func inHexTheCursorGoesByBytes() async {
        let bench = CoverageViewerPagerBench(width: 600, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(await bench.show(bench.document(Self.lines, .hex)))
        pager.perform(.right)
        pager.perform(.right)
        #expect(await bench.wait { pager.position?.offset == 2 })
        pager.perform(.left)
        #expect(await bench.wait { pager.position?.offset == 1 })
        pager.perform(.wordLeft)
        #expect(await bench.wait { pager.position?.offset == 0 })
    }

    /// Words, for the cursor and for a double click.
    @Test
    internal func wordsAreLettersDigitsAndUnderscores() {
        #expect(TextPagerView.wordStart(after: 0, in: "ab_1 , cd") == 7)
        #expect(TextPagerView.wordStart(before: 9, in: "ab_1 , cd") == 7)
        #expect(TextPagerView.wordRange(around: 1, in: "ab_1 , cd") == 0..<4)
        #expect(TextPagerView.wordRange(around: 5, in: "ab_1 , cd") == 5..<6)
        #expect(TextPagerView.wordRange(around: 2, in: "ab") == 2..<2)
        // Half a surrogate pair counts as part of a word.
        #expect(TextPagerView.wordRange(around: 0, in: "😀a ") == 0..<3)
    }

    /// A click puts the cursor, Shift+click selects to it, a double click selects a word, a
    /// triple click a row; dragging selects and scrolls; the context menu and the text under
    /// the mouse are told.
    @Test
    internal func theMouseSelects() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        let menu = NSMenu()
        pager.contextMenu = { menu }
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        func click(_ row: CGFloat, _ column: CGFloat, _ clicks: Int, _ flags: NSEvent.ModifierFlags) throws {
            pager.mouseDown(
                with: try #require(bench.mouse(.leftMouseDown, row: row, column: column, clicks: clicks, flags: flags))
            )
        }
        try click(0, 5, 1, [])
        #expect(pager.position?.offset == 5 && bench.window.firstResponder === pager)
        try click(0, 9, 1, .shift)
        #expect(pager.selection == 5..<9)
        try click(0, 9, 2, [])
        #expect(pager.selection == 8..<13)
        try click(1, 2, 3, [])
        let row = Int64(Self.lines.utf8.count / 60)
        #expect(pager.selection == row..<2 * row)
        pager.mouseDragged(with: try #require(bench.mouse(.leftMouseDragged, row: 2, column: 3, clicks: 1, flags: [])))
        #expect(pager.selection?.upperBound == 2 * row + 3)
        // Above and below the text the drag scrolls.
        pager.mouseDragged(with: try #require(bench.mouse(.leftMouseDragged, row: 40, column: 0, clicks: 1, flags: [])))
        #expect(await bench.wait { (pager.position?.line ?? 0) > 2 })
        pager.mouseDragged(with: try #require(bench.mouse(.leftMouseDragged, row: -3, column: 0, clicks: 1, flags: [])))
        #expect(
            pager.menu(for: try #require(bench.mouse(.rightMouseDown, row: 0, column: 0, clicks: 1, flags: [])))
                === menu
        )
        let location = try #require(bench.mouse(.leftMouseDown, row: 0, column: 2, clicks: 1, flags: []))
            .locationInWindow
        #expect(pager.text(at: location)?.index == 2)
    }

    /// A selection is drawn as the selected text of the key view, or more quietly otherwise.
    @Test
    internal func aSelectionIsDrawnByWhoHasTheKeyboard() async throws {
        let bench = CoverageViewerPagerBench(width: 400, height: 200)
        defer { bench.close() }
        let pager = bench.pager
        #expect(await bench.show(bench.document(Self.lines, CoverageViewerPagerBench.wrapped)))
        pager.selectAll()
        let rep = try #require(pager.bitmapImageRepForCachingDisplay(in: pager.bounds))
        #expect(bench.window.makeFirstResponder(nil))
        pager.cacheDisplay(in: pager.bounds, to: rep)
        let quiet = rep.colorAt(x: 10, y: 10)
        #expect(bench.window.makeFirstResponder(pager))
        pager.cacheDisplay(in: pager.bounds, to: rep)
        #expect(rep.colorAt(x: 10, y: 10) != quiet)
    }
}
