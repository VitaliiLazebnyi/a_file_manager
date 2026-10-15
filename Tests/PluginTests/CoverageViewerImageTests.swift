import AFMKernel
import AppKit
import Foundation
import ImageIO
import Testing

@testable import ViewerPlugin

/// Images: what the decoder makes of unusual files, the bitmaps made for the size shown, and
/// the image view's zoom, fitting, centring, scrolling and animation.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerImageTests {
    private static func view(_ image: DecodedImage?, size: CGFloat = 200) -> ImageCanvasView {
        let view = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        if let image {
            view.show(image)
        }
        return view
    }

    private static func drawn(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Whether the pixel looks like the pictures of `CoverageViewerImages` (mostly green).
    private static func isPicture(_ rep: NSBitmapImageRep, _ column: Int, _ row: Int) -> Bool {
        guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else {
            return false
        }
        return color.greenComponent > 0.5 && color.redComponent < 0.4
    }

    /// Holds the calling thread until `semaphore` is signalled.
    private static func block(until semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    private static func wait(until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: 60)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    // MARK: Decoding

    /// Nothing, a file that is not there, text and a file cut short in its frames decode to nothing.
    @Test
    internal func whatIsNoImageDecodesToNothing() throws {
        #expect(ImageDecoder.decode(Data()) == nil)
        #expect(ImageDecoder.decode(Data("plain text".utf8)) == nil)
        #expect(ImageDecoder.decode(contentsOf: URL(fileURLWithPath: "/nonexistent/picture.png")) == nil)
        let tiff = try CoverageViewerImages.encoded(
            (0..<3).map { _ in try CoverageViewerImages.picture(60, 40) },
            type: "public.tiff"
        )
        #expect(ImageDecoder.decode(tiff.prefix(tiff.count * 9 / 10)) == nil)
    }

    /// A PDF names no size in pixels: it is made at the size of its picture (it was one pixel).
    @Test
    internal func aPictureWithoutASizeIsMeasured() throws {
        let pdf = try CoverageViewerImages.encoded([CoverageViewerImages.picture(64, 32)], type: "com.adobe.pdf")
        let image = try #require(ImageDecoder.decode(pdf))
        #expect(image.pixelSize == CGSize(width: 64, height: 32) && image.size == CGSize(width: 64, height: 32))
    }

    /// A photo turned by its orientation has the sides of the turned picture.
    @Test
    internal func aTurnedPhotoHasTurnedSides() throws {
        let jpeg = try CoverageViewerImages.encoded(
            [CoverageViewerImages.picture(30, 10)],
            type: "public.jpeg",
            properties: [:],
            frameProperties: [kCGImagePropertyOrientation: 6]
        )
        let image = try #require(ImageDecoder.decode(jpeg))
        #expect(image.pixelSize == CGSize(width: 10, height: 30) && image.size == CGSize(width: 10, height: 30))
    }

    /// Decoding stops when it is cancelled.
    @Test
    internal func decodingStopsWhenCancelled() throws {
        let flag = CancellationFlag()
        flag.cancel()
        let gif = try CoverageViewerImages.animation(count: 2, size: 10, delay: 0.1)
        #expect(ImageDecoder.decode(gif, cancellation: flag) == nil)
    }

    /// A HEIC sequence plays as an animation.
    @Test
    internal func aHEICSequenceIsAnAnimation() throws {
        let heics = try CoverageViewerImages.encoded(
            [CoverageViewerImages.picture(20, 10), CoverageViewerImages.picture(20, 10, red: 0.3)],
            type: "public.heics"
        )
        #expect(ImageDecoder.decode(heics)?.frames.count == 2)
    }

    /// The frames that would take too much memory are left out and counted; the first frame is
    /// handed over before the others.
    @Test
    internal func framesBeyondTheMemoryLimitAreLeftOut() throws {
        let gif = try CoverageViewerImages.animation(count: 3, size: 20, delay: 0.1)
        var early: DecodedImage?
        let image = try #require(ImageDecoder.decode(gif, memoryLimit: 1) { early = $0 })
        #expect(image.frames.count == 1 && image.framesDropped == 2)
        #expect(early?.frames.count == 1)
    }

    /// The properties of an image the file does not have are none; a number that is not there is 0.
    @Test
    internal func missingPropertiesAreNone() throws {
        let png = try CoverageViewerImages.encoded([CoverageViewerImages.picture(8, 8)], type: "public.png")
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(ImageDecoder.properties(of: source, at: 9).isEmpty)
        #expect(ImageDecoder.number(kCGImagePropertyPixelWidth, in: [:]) == 0)
        #expect(DecodedImage(frames: [], pixelSize: .zero).size == .zero)
        let small = try #require(ImageDecoder.decode(png, largestSide: 4))
        #expect(small.isDownsampled && small.size == CGSize(width: 4, height: 4))
        // Taller than its frame, though as wide: downsampled too.
        let taller = DecodedImage(frames: small.frames, pixelSize: CGSize(width: 4, height: 8))
        #expect(taller.isDownsampled)
        #expect(!DecodedImage(frames: small.frames, pixelSize: CGSize(width: 4, height: 4)).isDownsampled)
    }

    // MARK: Scaled bitmaps

    /// A picture in a colour space other than RGB is scaled into sRGB; a size of nothing gives none.
    @Test
    internal func grayPicturesAreScaledIntoRGB() throws {
        let gray = try CoverageViewerImages.grayPicture(40, 40)
        let scaled = try #require(ScaledFrameCache.scale(gray, width: 20, height: 20))
        #expect(scaled.colorSpace?.model == .rgb && scaled.width == 20)
        #expect(ScaledFrameCache.scale(gray, width: 0, height: 0) == nil)
    }

    /// A bitmap that is made after its size was forgotten is dropped.
    @Test
    internal func aBitmapForAForgottenSizeIsDropped() async throws {
        let frame = try CoverageViewerImages.picture(400, 400)
        let cache = ScaledFrameCache()
        #expect(cache.image(for: frame, width: 100, height: 100) == nil)
        // The main thread waits until the bitmap has been made, then forgets the size before it
        // hears of it.
        let made = DispatchSemaphore(value: 0)
        cache.queue.asyncAfter(deadline: .now() + ScaledFrameCache.settle * 2) { made.signal() }
        Self.block(until: made)
        cache.invalidate()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        #expect(cache.made == 0)
    }

    // MARK: The view

    /// Without an image the view shows nothing and tells nothing.
    @Test
    internal func anEmptyViewTellsNothing() throws {
        let view = Self.view(nil)
        #expect(view.zoom == 1 && view.imageSize == .zero && !view.isDownsampled)
        #expect(view.framesDropped == 0 && view.frameCount == 0 && view.currentFrame == nil)
        view.replaceFrames(with: DecodedImage(frames: [], pixelSize: .zero))
        #expect(view.frameCount == 0)
        let rep = try Self.drawn(view)
        #expect(!Self.isPicture(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2))
        #expect(ImageCanvasView.pixelsPerPoint(window: nil, screen: nil) == 1)
    }

    /// An image is drawn at the top left, or in the middle when it is centred.
    @Test
    internal func centredImagesAreDrawnInTheMiddle() throws {
        let image = try #require(
            ImageDecoder.decode(
                try CoverageViewerImages.encoded([CoverageViewerImages.picture(20, 20)], type: "public.png")
            )
        )
        let view = Self.view(image)
        let canvas = try #require(view.documentView)
        var rep = try Self.drawn(canvas)
        #expect(Self.isPicture(rep, 1, 1) && !Self.isPicture(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2))
        view.centered = true
        rep = try Self.drawn(canvas)
        #expect(!Self.isPicture(rep, 1, 1) && Self.isPicture(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2))
    }

    /// The zoom: as set, or fitted to the window, only shrinking with "larger only"; the wheel
    /// with Control and a pinch change it.
    @Test
    internal func theZoomFollowsTheFitAndTheGestures() throws {
        let image = try #require(
            ImageDecoder.decode(
                try CoverageViewerImages.encoded([CoverageViewerImages.picture(50, 50)], type: "public.png")
            )
        )
        let view = Self.view(image)
        let scale = ImageCanvasView.pixelsPerPoint(window: nil, screen: NSScreen.main)
        view.fit = .largerOnly
        #expect(view.zoom == 1)
        view.fit = .window
        #expect(abs(view.zoom - min(view.contentSize.width, view.contentSize.height) / (50 / scale)) < 0.001)
        view.setZoom(2)
        #expect(view.zoom == 2)
        view.scrollWheel(with: try CoverageViewerEvents.scroll(lines: 1, flags: .maskControl))
        #expect(abs(view.zoom - 2.2) < 0.001)
        view.scrollWheel(with: try CoverageViewerEvents.scroll(lines: -1, flags: .maskControl))
        #expect(abs(view.zoom - 2) < 0.001)
        view.magnify(with: try CoverageViewerEvents.magnify(0.5))
        #expect(abs(view.zoom - 3) < 0.001)
        // A narrower view fits again.
        view.fit = .window
        let before = view.zoom
        view.setFrameSize(NSSize(width: 100, height: 100))
        #expect(view.zoom < before)
    }

    /// The arrow keys and the wheel scroll an image bigger than the view.
    @Test
    internal func aBigImageScrolls() throws {
        let image = try #require(
            ImageDecoder.decode(
                try CoverageViewerImages.encoded([CoverageViewerImages.picture(2_000, 2_000)], type: "public.png")
            )
        )
        let view = Self.view(image)
        view.setZoom(1)
        let start = view.contentView.bounds.origin
        view.scroll(byX: 40, y: -40)
        #expect(view.contentView.bounds.origin.x == start.x + 40)
        // The wheel without Control scrolls and leaves the zoom alone.
        view.scrollWheel(with: try CoverageViewerEvents.preciseScroll(vertical: 0, horizontal: -20))
        #expect(view.zoom == 1)
        // The end of a live resize draws again.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.documentView?.needsDisplay = false
        view.viewDidEndLiveResize()
        #expect(view.documentView?.needsDisplay == true)
    }

    /// An animation goes on to its next frame by itself, is drawn while it plays, and takes the
    /// complete set of frames in place of the first one.
    @Test
    internal func animationsPlay() async throws {
        let gif = try CoverageViewerImages.animation(count: 3, size: 20, delay: 0.02)
        let animation = try #require(ImageDecoder.decode(gif, minimumDelay: 0.02))
        let first = DecodedImage(frames: [animation.frames[0]], pixelSize: animation.pixelSize)
        let view = Self.view(first)
        var changes = 0
        view.onZoomChange = { changes += 1 }
        view.replaceFrames(with: animation)
        #expect(view.frameCount == 3 && changes == 1)
        let shown = view.currentFrame
        #expect(await Self.wait { view.currentFrame !== shown })
        let rep = try Self.drawn(try #require(view.documentView))
        #expect(Self.isPicture(rep, 1, 1))
    }
}
