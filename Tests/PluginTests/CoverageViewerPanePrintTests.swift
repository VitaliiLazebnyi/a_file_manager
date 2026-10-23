import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Printing from the Lister: text (all of it, the selection, too long, stopped), images, PDF,
/// pages and RTF, and the pages of a text.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPanePrintTests {
    private static let text = (1...200).map { "Line \($0) of the text\n" }.joined()

    /// A text prints whole, or its selection when the user wants that; a text longer than the
    /// pages printed is cut, and the user told; printing that was stopped prints nothing.
    @Test
    internal func printingText() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.settings.printMargins = [10, 20, 30, 40]
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        pane.printContent()
        #expect(await bench.wait { bench.dialogs.operations.count == 1 })
        let whole = try #require(bench.dialogs.operations.last?.operation)
        #expect(whole.printInfo.leftMargin == 10 && whole.printInfo.bottomMargin == 40)
        #expect(((whole.view as? TextPrintView)?.lines.count ?? 0) >= 200)
        pane.pager.reveal(offset: 0, select: 0..<12, rowsAbove: 0, keepingSelection: false)
        #expect(await bench.wait { pane.pager.selection != nil })
        bench.interaction.choiceAnswers = [0, 1]
        pane.printContent()
        #expect(await bench.wait { bench.dialogs.operations.count == 2 })
        #expect((bench.dialogs.operations.last?.operation.view as? TextPrintView)?.lines.count == 1)
        pane.printContent()
        #expect(await bench.wait { bench.dialogs.operations.count == 3 })
        // Stopped while it is prepared, or another file shown meanwhile: nothing is printed.
        pane.printContent()
        pane.activity?.cancel.cancel()
        await CoverageViewerPagerBench.settleAlone()
        pane.printContent()
        pane.loadGeneration += 1
        #expect(await bench.wait { pane.activity == nil })
        await CoverageViewerPagerBench.settleAlone()
        #expect(bench.dialogs.operations.count == 3)
        // Longer than the pages that are printed.
        let long = String(repeating: "x\n", count: ViewerPane.printPageLimit * 80)
        let big = try #require(await bench.open(try bench.file("long.txt", text: long)))
        #expect(await bench.textShown(big))
        big.printContent()
        #expect(await bench.wait { bench.dialogs.operations.count == 4 })
        #expect(bench.interaction.log.last?.contains("pages that are printed at most") == true)
    }

    /// Images print scaled to the page, enlarged too when fitted to the window; PDF, pages and
    /// RTF print as themselves.
    @Test
    internal func printingWhatIsNoText() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let png = try CoverageViewerImages.encoded([CoverageViewerImages.picture(3_000, 20)], type: "public.png")
        let image = try #require(await bench.open(try bench.file("wide.png", png)))
        #expect(await bench.wait { image.imageView != nil })
        image.printContent()
        bench.settings.imageFit = .window
        image.printContent()
        #expect(bench.dialogs.operations.count == 2)
        let pdf = try CoverageViewerImages.encoded([CoverageViewerImages.picture(30, 20)], type: "com.adobe.pdf")
        let document = try #require(await bench.open(try bench.file("doc.pdf", pdf)))
        #expect(await bench.wait { document.pdfView != nil })
        document.printContent()
        #expect(bench.dialogs.printedPDFs.count == 1)
        bench.setup.bench.kernel.settings.set(false, forKey: "viewer.htmlAsText")
        let page = try #require(await bench.open(try bench.file("page.html", text: "<p>Page</p>")))
        page.setMode(.media)
        #expect(await bench.wait { page.webView != nil })
        page.printContent()
        let rtf = "{\\rtf1\\ansi Rich}"
        let rich = try #require(await bench.open(try bench.file("note.rtf", text: rtf)))
        #expect(await bench.wait { rich.richText != nil })
        rich.printContent()
        #expect(bench.dialogs.operations.count == 4)
    }

    /// The rows chosen for printing: none of a part that is not indexed, the ones of the range,
    /// and at most as many as asked for.
    @Test
    internal func theRowsForPrinting() {
        let source = DataByteSource(Data(Self.text.utf8))
        let layout = ViewerLayout.text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8))
        let unindexed = TextDocument(source: source, encoding: .utf8, bomLength: 0, layout: layout, reusing: nil)
        let pageRows = ViewerPane.printPageLimit * 60
        #expect(
            ViewerPane.printableText(of: unindexed, in: 0..<100, maxRows: pageRows, cancellation: CancellationFlag())
                .lines.isEmpty
        )
        let document = TextDocument(source: source, encoding: .utf8, bomLength: 0, layout: layout, reusing: nil)
        document.buildIndex(parallel: false, scanning: .standard) {
            // Not watched here.
        }
        let part = ViewerPane.printableText(
            of: document,
            in: 0..<30,
            maxRows: pageRows,
            cancellation: CancellationFlag()
        )
        #expect(part.lines == ["Line 1 of the text", "Line 2 of the text"] && !part.truncated)
        #expect(part.text == "Line 1 of the text\nLine 2 of the text\n")
        let cut = ViewerPane.printableText(
            of: document,
            in: document.content,
            maxRows: 3,
            cancellation: CancellationFlag()
        )
        #expect(cut.lines.count == 3 && cut.truncated)
    }

    /// The pages of a printed text: how many there are, where each lies, and drawing them.
    @Test
    internal func thePagesOfAText() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let page = NSSize(width: 300, height: 200)
        let view = TextPrintView(lines: (1...30).map { "Row \($0)" }, font: font, pageSize: page)
        var range = NSRange(location: 0, length: 0)
        #expect(view.knowsPageRange(&range) && range.location == 1 && range.length == view.pageCount)
        #expect(view.isFlipped && view.pageCount > 1)
        #expect(view.rectForPage(2).minY > 0)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        view.draw(NSRect(x: 0, y: view.bounds.height + 100, width: 10, height: 10))
        let empty = TextPrintView(lines: [], font: font, pageSize: page)
        empty.draw(empty.bounds)
        #expect(empty.pageCount == 1)
    }
}
