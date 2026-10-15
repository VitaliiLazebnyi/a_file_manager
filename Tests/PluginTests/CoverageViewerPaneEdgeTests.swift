import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The pane at its edges: files read slowly or from elsewhere, results that come too late,
/// entries run after the pane changed or went away, folders, and links.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPaneEdgeTests {
    private static let text = (1...200).map { "Line \($0) of the text\n" }.joined()

    /// A file system that serves `source` as the file `held:///name`.
    private static func held(_ source: CoverageViewerHeldSource, in bench: CoverageViewerPaneBench) {
        let length = source.length
        let provider = CoverageViewerProvider(
            scheme: "held",
            entry: { url in
                FileItem(url: url, name: url.lastPathComponent, kind: .init(), stat: .init(size: length))
            },
            reader: { _ in CoverageViewerSourceReader(source) }
        )
        bench.setup.bench.kernel.fileSystems.register(provider)
    }

    private static func pane(_ bench: CoverageViewerPaneBench, _ url: URL) async -> ViewerPane? {
        bench.setup.plugin.view(url)
        guard let pane = bench.setup.plugin.windows.last?.pane else {
            return nil
        }
        bench.prepare(pane)
        return await bench.wait { pane.loaded != nil } ? pane : nil
    }

    /// A text read slowly: the status line says it is being read, and a line the index has not
    /// reached is not there yet.
    @Test
    internal func aTextReadSlowly() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        var data = Data()
        let line = Data("A line of a long text that is read slowly\n".utf8)
        while data.count < 10 << 20 {
            data.append(line)
        }
        let source = CoverageViewerHeldSource(data)
        defer { source.release() }
        Self.held(source, in: bench)
        source.hold(from: 1 << 20)
        let slow = try #require(URL(string: "held:///slow.txt"))
        let pane = try #require(await Self.pane(bench, slow))
        #expect(await bench.wait { pane.statusText.hasPrefix("Reading…") })
        source.release()
        source.hold(from: 6 << 20)
        #expect(await bench.wait { pane.pager.document != nil && pane.pager.position != nil })
        bench.interaction.promptAnswers = [.text("200000")]
        pane.goToLine()
        #expect(await bench.wait { bench.interaction.log.last?.contains("has not been read yet") == true })
    }

    /// A search of a file that is not on the local disk goes chunk by chunk; its progress is
    /// shown while it runs, and dropped once nobody waits for it.
    @Test
    internal func searchingAFileFromElsewhere() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        var data = Data()
        while data.count < 3 << 20 {
            data.append(Data("words and more words\n".utf8))
        }
        let source = CoverageViewerHeldSource(data)
        Self.held(source, in: bench)
        let words = try #require(URL(string: "held:///words.txt"))
        let pane = try #require(await Self.pane(bench, words))
        #expect(await bench.textShown(pane))
        pane.lastSearch = ("no such thing", SearchOptions())
        pane.search(backwards: false)
        // A second search while one runs does not start.
        pane.search(backwards: true)
        pane.activity = nil
        #expect(await bench.wait { bench.interaction.log.last?.contains("was not found") == true })
        // What a search brings is shown only while it is wanted, and its errors are reported.
        let document = try #require(pane.pager.document)
        let generation = pane.loadGeneration
        let stopped = CancellationFlag()
        stopped.cancel()
        let count = bench.interaction.log.count
        pane.searchFinished(.success(0..<5), for: "x", in: document, generation: generation, cancel: stopped)
        #expect(bench.interaction.log.count == count && pane.pager.selection == nil)
        pane.searchFinished(
            .failure(CocoaError(.fileReadUnknown)),
            for: "x",
            in: document,
            generation: generation,
            cancel: CancellationFlag()
        )
        #expect(bench.interaction.log.last == "inform: Find")
    }

    /// Entries of a menu that was opened before the pane changed, or went away, do nothing.
    @Test
    internal func entriesRunAfterTheirPaneChanged() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let notes = try bench.file("notes.txt", text: Self.text)
        let pane = try #require(await bench.open(notes))
        bench.setup.commands.register(Command(.edit, "Edit")) { _ in
            Issue.record("The editor was opened")
        }
        let file = pane.menuEntries("File")
        pane.clear()
        bench.dialogs.saveAnswer = bench.folder.appendingPathComponent("copy.txt")
        file.compactMap { $0 }.first { $0.title == "Save as…" }?.run()
        file.compactMap { $0 }.first { $0.title == "Edit" }?.run()
        #expect(bench.dialogs.proposedNames.isEmpty)
        var options: [ViewerAction?] = []
        autoreleasepool {
            let gone = ViewerPane(
                kernel: bench.setup.bench.kernel,
                settings: bench.settings,
                temporaryCopies: TemporaryCopies(),
                isEmbedded: false
            )
            options = gone.menuEntries("Options")
        }
        let wrap = bench.settings.wrap
        let caret = bench.settings.caret
        let center = bench.settings.centersImages
        for title in ["Wrap text", "Show text cursor", "Center images"] {
            options.compactMap { $0 }.first { $0.title == title }?.run()
        }
        #expect(bench.settings.wrap == wrap && bench.settings.caret == caret && bench.settings.centersImages == center)
    }

    /// What does nothing: finding without text, a second search, copying without a selection,
    /// a context menu without a window, and a code page that is only a bracket.
    @Test
    internal func requestsThatDoNothing() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let png = try CoverageViewerImages.encoded([CoverageViewerImages.picture(30, 20)], type: "public.png")
        let image = try #require(await bench.open(try bench.file("picture.png", png)))
        image.find()
        #expect(bench.interaction.log.isEmpty)
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        pane.copySelection(asHex: false)
        bench.interaction.promptAnswers = [.text("(")]
        pane.askForCodePage()
        #expect(bench.interaction.log.last?.contains("is not available") == true)
        let loose = ViewerPane(
            kernel: bench.setup.bench.kernel,
            settings: bench.settings,
            temporaryCopies: TemporaryCopies(),
            isEmbedded: false
        )
        loose.load(ViewerItem(source: .text("https://example.com"), title: "Link"))
        #expect(await bench.wait { loose.pager.position != nil })
        #expect(loose.makeContextMenu() == nil)
        loose.present()
        let fresh = ViewerPane(
            kernel: bench.setup.bench.kernel,
            settings: bench.settings,
            temporaryCopies: TemporaryCopies(),
            isEmbedded: false
        )
        fresh.present()
        fresh.relayout()
        #expect(fresh.loaded == nil)
    }

    /// The link around a place in a text: the word there, when it is one.
    @Test
    internal func theLinkUnderTheMouse() {
        let text = "see https://example.com/a here"
        #expect(ViewerPane.link(in: text, at: 10)?.absoluteString == "https://example.com/a")
        #expect(ViewerPane.link(in: text, at: 4)?.absoluteString == "https://example.com/a")
        #expect(ViewerPane.link(in: text, at: 1) == nil)
        #expect(ViewerPane.link(in: text, at: 100) == nil)
    }

    /// Folders: viewing one is refused, counting one of an unknown file system does nothing,
    /// one on a server is counted in part, and an overtaken count is dropped.
    @Test
    internal func folders() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.setup.plugin.view(bench.folder)
        let pane = try #require(bench.setup.plugin.windows.last?.pane)
        #expect(await bench.wait { pane.failure?.isEmpty == false })
        pane.showFolder(try #require(URL(string: "unknown:///folder")), name: "folder")
        await CoverageViewerPagerBench.settleAlone()
        #expect(pane.folderSummary == nil)
        let provider = CoverageViewerProvider(scheme: "plain", entry: { _ in nil }) { _ in
            CoverageViewerReader(Data())
        }
        bench.setup.bench.kernel.fileSystems.register(provider)
        pane.showFolder(try #require(URL(string: "plain:///folder")), name: "plain")
        #expect(await bench.wait { pane.folderSummary != nil })
        bench.setup.memory.isLocal = false
        pane.showFolder(bench.setup.memory.url("/A"), name: "A")
        pane.showFolder(bench.setup.memory.url("/A"), name: "A again")
        #expect(await bench.wait { pane.folderSummary?.files == 3 })
    }

    /// Views of rich modes: their links, ends and titles reach the pane; an image too big is
    /// shown downsampled and says so; results of an earlier showing are dropped.
    @Test
    internal func richViewsReportToThePane() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.settings.playerVolume = 0
        bench.setup.bench.kernel.settings.set(false, forKey: "viewer.htmlAsText")
        let page = try #require(await bench.open(try bench.file("page.html", text: "<p>Page</p>")))
        page.setMode(.media)
        #expect(await bench.wait { page.webView != nil })
        page.webView?.onLink(try #require(URL(string: "https://example.com/b")))
        #expect(bench.links.opened.last?.absoluteString == "https://example.com/b")
        let sound = try #require(
            await bench.open(try bench.file("tone.wav", CoverageViewerMediaFiles.wav(seconds: 0.2)))
        )
        #expect(await bench.wait { sound.mediaView != nil })
        var titles: [String] = []
        var steps: [Int] = []
        sound.onTitleChange = { titles.append($0) }
        sound.onStep = { steps.append($0) }
        sound.mediaView?.onTitle?("Track")
        sound.mediaView?.onEnd()
        #expect(titles == ["Track"] && steps == [1])
        let png = try CoverageViewerImages.encoded([CoverageViewerImages.picture(9_000, 10)], type: "public.png")
        let big = try #require(await bench.open(try bench.file("big.png", png)))
        #expect(await bench.wait { big.imageView != nil })
        #expect(big.statusText.contains("shown downsampled"))
        let frames = try #require(big.imageView?.currentFrame)
        big.imageView?
            .replaceFrames(
                with: DecodedImage(frames: [(frames, 0.1), (frames, 0.1)], pixelSize: .zero, framesDropped: 2)
            )
        #expect(big.statusText.contains("2 frames left out"))
        let gif = try CoverageViewerImages.animation(count: 3, size: 20, delay: 0.1)
        let animation = try #require(await bench.open(try bench.file("anim.gif", gif)))
        animation.present()
        animation.present()
        #expect(await bench.wait { animation.imageView?.frameCount == 3 })
        // A file whose size no mode needs whole is not read whole.
        #expect(
            ViewerPane.wholeData(
                of: DataByteSource(Data(count: 10)),
                at: bench.folder,
                limit: 5,
                cancellation: CancellationFlag()
            ) == nil
        )
    }

    /// Quick Look shows a file it is configured for.
    @Test
    internal func quickLookShowsItsFiles() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let slides = try #require(await bench.open(try bench.file("slides.key", text: "not really slides")))
        #expect(await bench.wait { Self.hasPreview(slides) })
        // Media again goes on to Quick Look.
        slides.setMode(.media)
        slides.setMode(.media)
        #expect(slides.mode == .preview)
        slides.internalOnly = true
        slides.setMode(.media)
        #expect(slides.mode == .media)
        slides.setMode(.text)
        #expect(await bench.textShown(slides))
    }

    /// A text wrapped at the window's edge is laid out anew for a new width, but not while the
    /// window is being resized; a text that is not wrapped needs nothing.
    @Test
    internal func aNewWidthLaysTheTextOutAgain() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        let shown = pane.pager.document
        pane.pager.setFrameSize(NSSize(width: 300, height: 300))
        pane.layOutAfterResize(whileResizing: true)
        #expect(pane.pager.document === shown)
        pane.layOutAfterResize(whileResizing: false)
        #expect(await bench.textShown(pane) && pane.pager.document !== shown)
        pane.viewDidEndLiveResize()
        pane.pager.clear()
        pane.relayout()
        #expect(await bench.textShown(pane))
    }

    /// An HTML page whose charset is not named is decoded with the code page of the font.
    @Test
    internal func htmlThatIsNotWhatItWas() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let latin = try bench.file("latin.html", Data("<p>caf".utf8) + Data([0xE9]) + Data("</p>".utf8))
        let pane = try #require(await bench.open(latin))
        #expect(await bench.textShown(pane))
    }

    /// The keyboard: the pane itself, and a pane that goes away while it is in a window.
    @Test
    internal func theKeyboardAndAPaneThatGoesAway() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        weak var gone: ViewerPane?
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        autoreleasepool {
            let pane = ViewerPane(
                kernel: bench.setup.bench.kernel,
                settings: bench.settings,
                temporaryCopies: TemporaryCopies(),
                isEmbedded: false
            )
            window.contentView = pane
            #expect(window.makeFirstResponder(pane) && pane.hasKeyboard)
            gone = pane
        }
        window.contentView = NSView()
        #expect(await bench.wait { gone == nil })
    }

    private static func hasPreview(_ view: NSView) -> Bool {
        view.subviews.contains { String(describing: type(of: $0)).contains("QLPreviewView") || hasPreview($0) }
    }
}
