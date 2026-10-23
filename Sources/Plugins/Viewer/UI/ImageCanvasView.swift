import AppKit

/// The image mode (spec 10 › Image mode): zoom, fitting, centring, turning, animation.
///
/// Main thread only; the image arrives decoded.
internal final class ImageCanvasView: NSScrollView {
    private final class Canvas: NSView {
        var frameImage: CGImage?
        var imageRect = NSRect.zero
        var quarterTurns = 0
        /// An animation, or a window being resized, is drawn faster and a little rougher: the
        /// whole frame is resampled on every draw.
        var isAnimated = false
        /// The frame at the size it is drawn at, for an image that is shown smaller than it is.
        let scaled = ScaledFrameCache()

        override func draw(_: NSRect) {
            guard let frameImage, let context = NSGraphicsContext.current?.cgContext else {
                return
            }
            context.saveGState()
            context.interpolationQuality = isAnimated || inLiveResize ? .low : .high
            context.translateBy(x: imageRect.midX, y: imageRect.midY)
            context.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
            let turned = !quarterTurns.isMultiple(of: 2)
            let size = turned ? CGSize(width: imageRect.height, height: imageRect.width) : imageRect.size
            let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            // Scrolling and drawing again take the bitmap made for this size; while it is made, and
            // while an animation or the window's edge changes the picture, the frame is resampled.
            let scale = window?.backingScaleFactor ?? 1
            let width = Int((size.width * scale).rounded())
            let height = Int((size.height * scale).rounded())
            let bitmap =
                isAnimated || inLiveResize
                ? scaled.readyImage(for: frameImage, width: width, height: height)
                : scaled.image(for: frameImage, width: width, height: height)
            if let bitmap {
                context.interpolationQuality = .default
                context.draw(bitmap, in: rect)
            } else {
                // Until the bitmap for this size exists the frame is resampled on the main
                // thread: roughly, which costs a fraction of resampling it well.
                context.interpolationQuality = .low
                context.draw(frameImage, in: rect)
            }
            context.restoreGState()
        }
    }

    private let canvas = Canvas()
    private var image: DecodedImage?
    private var frameIndex = 0
    /// Set on the main thread, read in `deinit`.
    nonisolated(unsafe) private var timer: Timer?
    private var manualZoom: CGFloat?
    private var quarterTurns = 0
    /// How the image is fitted to the window; setting it drops a zoom chosen by hand.
    internal var fit = ImageFit.actualSize {
        didSet {
            manualZoom = nil
            arrange()
        }
    }
    /// Whether an image smaller than the window is drawn in its middle rather than at its top left.
    internal var centered = false { didSet { arrange() } }
    /// Called when the zoom factor changed.
    internal var onZoomChange: () -> Void = {
        // Nobody shows the zoom until the pane sets this.
    }

    /// The image as it is shown now, for printing.
    internal var currentFrame: CGImage? { image?.frames[frameIndex].image }
    /// The size of the file's image in pixels; zero before an image is shown.
    internal var imageSize: CGSize { image?.pixelSize ?? .zero }
    /// Whether the image shown has fewer pixels than the file's (it was too large to decode whole).
    internal var isDownsampled: Bool { image?.isDownsampled ?? false }
    /// The number of frames of an animation that were left out for want of memory.
    internal var framesDropped: Int { image?.framesDropped ?? 0 }
    /// The frames of the image shown: 1 for a still image, 0 before one is shown.
    internal var frameCount: Int { image?.frames.count ?? 0 }

    /// The size of the turned image at 100 %, in points: one pixel of the image on one pixel
    /// of the screen.
    private var turnedSize: CGSize {
        guard let size = image?.size else {
            return .zero
        }
        let scale = Self.pixelsPerPoint(window: window, screen: NSScreen.main)
        return !quarterTurns.isMultiple(of: 2)
            ? CGSize(width: size.height / scale, height: size.width / scale)
            : CGSize(width: size.width / scale, height: size.height / scale)
    }

    /// The factor the image is drawn with; 1 is actual size.
    internal var zoom: CGFloat {
        if let manualZoom {
            return manualZoom
        }
        let size = turnedSize
        let area = contentSize
        guard size.width > 0, size.height > 0, fit != .actualSize else {
            return 1
        }
        let fitting = min(area.width / size.width, area.height / size.height)
        return fit == .window ? fitting : min(1, fitting)
    }

    /// How many bitmaps of the image at the size it is shown at were made (for tests).
    internal var scaledBitmapsMade: Int { canvas.scaled.made }

    /// The queue the scaled bitmap is made on: a test holds it still while it asks for sizes, so how long
    /// that takes on a busy machine decides nothing.
    internal var scalingQueue: DispatchQueue { canvas.scaled.queue }

    override internal init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        documentView = canvas
        canvas.scaled.onReady = { [weak canvas] in canvas?.needsDisplay = true }
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    /// The pixels of the screen per point: those of the window, else of the main screen, else 1.
    internal static func pixelsPerPoint(window: NSWindow?, screen: NSScreen?) -> CGFloat {
        window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 1
    }

    /// Shows a new image from its first frame, at the fitting zoom and not turned; an animation starts playing.
    internal func show(_ image: DecodedImage) {
        timer?.invalidate()
        canvas.scaled.invalidate()
        self.image = image
        frameIndex = 0
        manualZoom = nil
        quarterTurns = 0
        canvas.isAnimated = image.frames.count > 1
        arrange()
        scheduleNextFrame()
    }

    /// Takes the complete animation in place of its first frame, which was shown early; zoom and
    /// turns stay.
    internal func replaceFrames(with image: DecodedImage) {
        guard self.image != nil else {
            return
        }
        timer?.invalidate()
        canvas.scaled.invalidate()
        self.image = image
        frameIndex = 0
        canvas.isAnimated = image.frames.count > 1
        canvas.frameImage = currentFrame
        canvas.needsDisplay = true
        onZoomChange()
        scheduleNextFrame()
    }

    /// Zooms to `factor` (1 is actual size), kept between 0.01 and 64, until the fit is set again.
    internal func setZoom(_ factor: CGFloat) {
        manualZoom = min(64, max(0.01, factor))
        arrange()
    }

    /// Turns the image by `turns` quarter turns, to the right for positive ones (Rotate right).
    internal func rotate(by turns: Int) {
        quarterTurns = ((quarterTurns + turns) % 4 + 4) % 4
        arrange()
    }

    /// ← and → scroll the image (spec 10 › Image mode).
    internal func scroll(byX deltaX: CGFloat, y deltaY: CGFloat) {
        let origin = contentView.bounds.origin
        contentView.scroll(
            to:
                contentView.constrainBoundsRect(
                    NSRect(
                        origin: NSPoint(x: origin.x + deltaX, y: origin.y + deltaY),
                        size: contentView.bounds.size
                    )
                )
                .origin
        )
        reflectScrolledClipView(contentView)
    }

    override internal func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    /// The picture drawn roughly while the window's edge moved is drawn well again, from the
    /// bitmap that is made for its size.
    override internal func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        canvas.needsDisplay = true
    }

    private func arrange() {
        guard image != nil else {
            return
        }
        let factor = zoom
        let size = turnedSize
        let area = contentSize
        let shown = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        let document = CGSize(width: max(shown.width, area.width), height: max(shown.height, area.height))
        canvas.frame = NSRect(origin: .zero, size: document)
        // The view's origin is at the bottom left; an image that is not centred starts at the top left.
        canvas.imageRect =
            centered
            ? NSRect(
                x: (document.width - shown.width) / 2,
                y: (document.height - shown.height) / 2,
                width: shown.width,
                height: shown.height
            )
            : NSRect(x: 0, y: document.height - shown.height, width: shown.width, height: shown.height)
        canvas.quarterTurns = quarterTurns
        canvas.frameImage = currentFrame
        canvas.needsDisplay = true
        if manualZoom == nil { canvas.scroll(NSPoint(x: 0, y: document.height - area.height)) }
        onZoomChange()
    }

    private func scheduleNextFrame() {
        guard let image, image.frames.count > 1 else {
            return
        }
        timer = Timer.scheduledTimer(
            withTimeInterval: image.frames[frameIndex].delay,
            repeats: false
        ) { [weak self] _ in
            // A scheduled timer fires on the main run loop.
            MainActor.assumeIsolated { self?.showNextFrame() }
        }
    }

    private func showNextFrame() {
        frameIndex = (frameIndex + 1) % max(1, frameCount)
        canvas.frameImage = currentFrame
        canvas.needsDisplay = true
        scheduleNextFrame()
    }

    override internal func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.scrollingDeltaY != 0 {
            setZoom(zoom * (event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1))
        } else {
            super.scrollWheel(with: event)
        }
    }

    override internal func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification))
    }

    deinit { timer?.invalidate() }
}
