import AFMKernel
import AppKit
import Foundation
import PDFKit
import TestSupport
import Testing

@testable import ViewerPlugin

/// What a Lister pane does with results that come late (the pane moved on meanwhile), files of
/// other file systems shown in the rich modes, and reads that fail or come back short. The work
/// of a pane runs on its work queue; a barrier on that queue waits until what was handed to it
/// has run, and its answers then wait for the main thread.
@MainActor
@Suite(.serialized)
internal struct CovViewPaneLateTests {
    /// A file system `covview` that serves `held` as each of its files, `size` bytes long as
    /// listed (the length of `held` when nil).
    private static func serve(_ held: CoverageViewerHeldSource, _ bench: CoverageViewerPaneBench, size: Int64? = nil) {
        let length = size ?? held.length
        let provider = CoverageViewerProvider(
            scheme: "covview",
            entry: { url in
                FileItem(url: url, name: url.lastPathComponent, kind: .init(), stat: .init(size: length))
            },
            reader: { _ in CoverageViewerSourceReader(held) }
        )
        bench.setup.bench.kernel.fileSystems.register(provider)
    }

    private static func url(_ name: String) throws -> URL {
        try #require(URL(string: "covview:///" + name))
    }

    /// The texts of the labels in `view` and below it.
    private static func labels(_ view: NSView) -> [String] {
        view.subviews.flatMap { subview in ((subview as? NSTextField).map { [$0.stringValue] } ?? []) + labels(subview)
        }
    }

    /// Waits until everything handed to the pane's work queue has run.
    private static func drain(_ pane: ViewerPane) {
        pane.workQueue.sync(flags: .barrier) {
            // Everything before has run.
        }
    }

    /// The count of a folder that comes when the pane has moved on is dropped.
    @Test
    internal func aFolderCountedTooLateIsDropped() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: "notes")))
        pane.showFolder(bench.setup.memory.url("/A"), name: "A")
        Self.drain(pane)
        pane.clear(message: "Moved on")
        await CoverageViewerPagerBench.settleAlone()
        #expect(pane.folderSummary == nil && pane.item == nil)
    }

    /// A PDF on another file system is read whole and shown.
    @Test
    internal func aPDFOfAnotherFileSystemIsShown() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let data = try CoverageViewerImages.encoded([CoverageViewerImages.picture(30, 20)], type: "com.adobe.pdf")
        Self.serve(CoverageViewerHeldSource(data), bench)
        let pane = try #require(await bench.open(try Self.url("doc.pdf")))
        #expect(await bench.wait { pane.pdfView?.document?.pageCount == 1 })
    }

    /// An HTML file that is shorter than it said when its tags are to be removed says that it
    /// changed.
    @Test
    internal func anHTMLFileThatBecameShorterSaysSo() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        Self.serve(CoverageViewerHeldSource("<p>Short page</p>"), bench, size: 400)
        let pane = try #require(await bench.open(try Self.url("page.html")))
        #expect(await bench.wait { pane.failure != nil })
        #expect(pane.failure == ViewerError.fileChanged.localizedDescription && pane.mode == .html)
    }

    /// An HTML file whose tags are still being removed when another mode is chosen is not shown
    /// as a page afterwards.
    @Test
    internal func tagsRemovedForAModeLeftMeanwhileAreDropped() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        // More than the first block a server's file is read in (256 KB), which holds the sample.
        let page = "<p>" + String(repeating: "word ", count: 200_000) + "</p>"
        let source = CoverageViewerHeldSource(page)
        source.hold(from: 256 << 10)
        Self.serve(source, bench)
        bench.setup.plugin.view(try Self.url("page.html"))
        let pane = try #require(bench.setup.plugin.windows.last?.pane)
        bench.prepare(pane)
        #expect(await bench.wait { pane.loaded != nil && source.waitingReads > 0 })
        #expect(pane.mode == .html && pane.htmlLinks.isEmpty)
        pane.setMode(.text)
        source.release()
        Self.drain(pane)
        #expect(await bench.textShown(pane))
        #expect(pane.mode == .text && pane.failure == nil)
    }

    /// Tags that were to be removed for a mode left before the work began are not removed.
    @Test
    internal func tagsOfAModeLeftBeforeTheWorkBeganAreLeft() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.setup.bench.kernel.settings.set(false, forKey: "viewer.htmlAsText")
        Self.serve(CoverageViewerHeldSource("<p>A <a href=\"x.html\">link</a></p>"), bench)
        let pane = try #require(await bench.open(try Self.url("page.html")))
        #expect(await bench.textShown(pane))
        // The work queue waits behind this until the mode was changed twice.
        let gate = DispatchSemaphore(value: 0)
        pane.workQueue.async(flags: .barrier) { gate.wait() }
        pane.setMode(.html)
        pane.setMode(.text)
        gate.signal()
        Self.drain(pane)
        await CoverageViewerPagerBench.settleAlone()
        pane.setMode(.html)
        // Removed now, for the mode chosen now.
        #expect(await bench.wait { pane.htmlLinks == ["x.html"] })
    }

    /// A sound on another file system whose copy cannot be read says so; one whose copy is
    /// stopped by moving on shows nothing of it.
    @Test
    internal func copiesThatFailOrAreStopped() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.setup.bench.kernel.settings.set(false, forKey: "viewer.multimedia")
        let source = CoverageViewerHeldSource(Data(count: 3 << 20))
        Self.serve(source, bench)
        let pane = try #require(await bench.open(try Self.url("tone.wav")))
        #expect(pane.mode != .media)
        source.fail(true)
        pane.setMode(.media)
        #expect(await bench.wait { Self.labels(pane).contains("The file cannot be shown in this mode.") })
        #expect(pane.mediaView == nil)
        source.fail(false)
        let stopped = try #require(await bench.open(try Self.url("other.wav")))
        source.hold(from: 1 << 20)
        stopped.setMode(.media)
        #expect(await bench.wait { source.waitingReads > 0 })
        stopped.setMode(.hex)
        source.release()
        Self.drain(stopped)
        await CoverageViewerPagerBench.settleAlone()
        #expect(stopped.mode == .hex && stopped.mediaView == nil)
    }

    /// The first frame of an animation that comes when another mode was chosen is not shown.
    @Test
    internal func aFirstFrameThatComesTooLateIsDropped() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let gif = try CoverageViewerImages.animation(count: 3, size: 20, delay: 0.1)
        let pane = try #require(await bench.open(try bench.file("anim.gif", gif)))
        #expect(pane.mode == .media)
        Self.drain(pane)
        pane.setMode(.hex)
        await CoverageViewerPagerBench.settleAlone()
        #expect(pane.imageView == nil)
    }

    /// A text whose reads fail says so in the status line.
    @Test
    internal func readErrorsOfATextAreShown() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        // More than the first block a server's file is read in (256 KB); the rest fails.
        let source = CoverageViewerHeldSource(String(repeating: "https://example.com\n", count: 50_000))
        source.hold(from: 256 << 10)
        Self.serve(source, bench)
        let pane = try #require(await bench.open(try Self.url("links.txt")))
        #expect(await bench.wait { source.waitingReads > 0 })
        source.fail(true)
        source.release()
        #expect(await bench.wait { pane.statusText.contains("Read error") })
    }

    /// A selection whose text cannot be read any more gives nothing to look up.
    @Test
    internal func aSelectionThatCannotBeReadOpensNothing() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: "notes")))
        #expect(await bench.textShown(pane))
        // The pager shows a text read straight from a source that then fails.
        let source = CoverageViewerHeldSource("https://example.com/a and more")
        let document = TextDocument(source: source, encoding: .utf8, layout: pane.layout)
        pane.pager.show(document, select: 0..<21, parallel: false)
        #expect(await bench.wait { pane.pager.document === document && pane.pager.selection == 0..<21 })
        source.fail(true)
        let menu = try #require(pane.makeContextMenu())
        let index = try #require(menu.items.firstIndex { $0.title == "Open the selection as a link in the browser" })
        menu.performActionForItem(at: index)
        Self.drain(pane)
        await CoverageViewerPagerBench.settleAlone()
        #expect(bench.links.opened.isEmpty)
        // Read again, it opens.
        source.fail(false)
        menu.performActionForItem(at: index)
        #expect(await bench.wait { bench.links.opened.map(\.absoluteString) == ["https://example.com/a"] })
    }
}
