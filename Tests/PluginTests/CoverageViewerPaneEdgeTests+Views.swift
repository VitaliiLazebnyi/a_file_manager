import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The pane with its views: rich modes, Quick Look, HTML that names no charset, and the keyboard.
extension CoverageViewerPaneEdgeTests {
    /// Whether `view` holds a Quick Look preview, at any depth.
    private static func hasPreview(_ view: NSView) -> Bool {
        view.subviews.contains { String(describing: type(of: $0)).contains("QLPreviewView") || hasPreview($0) }
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
}
