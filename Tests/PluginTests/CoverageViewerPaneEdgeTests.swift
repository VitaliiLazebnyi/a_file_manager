import AFMContracts
import AFMKernel
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
        file.compactMap(\.self).first { $0.title == "Save as…" }?.run()
        file.compactMap(\.self).first { $0.title == "Edit" }?.run()
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
            options.compactMap(\.self).first { $0.title == title }?.run()
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
        let sentence = "see https://example.com/a here"
        #expect(ViewerPane.link(in: sentence, at: 10)?.absoluteString == "https://example.com/a")
        #expect(ViewerPane.link(in: sentence, at: 4)?.absoluteString == "https://example.com/a")
        #expect(ViewerPane.link(in: sentence, at: 1) == nil)
        #expect(ViewerPane.link(in: sentence, at: 100) == nil)
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
        let provider = CoverageViewerProvider(
            scheme: "plain",
            entry: { _ in nil },
            reader: { _ in CoverageViewerReader(Data()) }
        )
        bench.setup.bench.kernel.fileSystems.register(provider)
        pane.showFolder(try #require(URL(string: "plain:///folder")), name: "plain")
        #expect(await bench.wait { pane.folderSummary != nil })
        bench.setup.memory.isLocal = false
        pane.showFolder(bench.setup.memory.url("/A"), name: "A")
        pane.showFolder(bench.setup.memory.url("/A"), name: "A again")
        #expect(await bench.wait { pane.folderSummary?.files == 3 })
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
}
