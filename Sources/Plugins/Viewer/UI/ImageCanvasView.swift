import AFMKernel
import AppKit
import ImageIO

/// An image ready to draw: one frame, or the frames of an animation with their delays.
internal struct DecodedImage {
    internal var frames: [(image: CGImage, delay: Double)]
    /// The size of the file's image in pixels; the frames are smaller when it was downsampled.
    internal var pixelSize: CGSize
    /// Frames of an animation that were left out because together they would take too much
    /// memory (`ImageDecoder.animationMemoryLimit`): the animation is cut short.
    internal var framesDropped = 0

    /// The size the frames are drawn at for 100 %.
    internal var size: CGSize { frames.first.map { CGSize(width: $0.image.width, height: $0.image.height) } ?? .zero }
    internal var isDownsampled: Bool { size.width < pixelSize.width || size.height < pixelSize.height }
}

/// Decodes images with ImageIO.
///
/// A value-free namespace; `decode` is meant for a background thread and touches nothing shared.
internal enum ImageDecoder {
    /// No side of a decoded frame is longer than this: an image of several hundred megapixels
    /// is downsampled while it is decoded and never exists at full size in memory.
    internal static let largestSide = 8_192
    /// The frames of an animation may take this much memory together; the rest is left out.
    internal static let animationMemoryLimit = 512 << 20
    /// An image of more pixels than this is not decoded (a file that claims billions of pixels
    /// in a few kilobytes would take the memory of the computer to decode).
    internal static let pixelLimit = 400_000_000.0

    /// Nil when the data is no image ImageIO can read.
    ///
    /// `minimumDelay` is the shortest time a frame of an animation stays (the specification's
    /// `GifMinDelay`). Photos are turned as their EXIF orientation says.
    internal static func decode(
        _ data: Data,
        minimumDelay: Double = 0.08,
        largestSide: Int = largestSide,
        pixelLimit: Double = pixelLimit,
        memoryLimit: Int = animationMemoryLimit,
        cancellation: CancellationFlag = CancellationFlag(),
        firstFrame: ((DecodedImage) -> Void)? = nil
    ) -> DecodedImage? {
        decode(
            CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            minimumDelay: minimumDelay,
            largestSide: largestSide,
            pixelLimit: pixelLimit,
            memoryLimit: memoryLimit,
            cancellation: cancellation,
            firstFrame: firstFrame
        )
    }

    /// The same for a file on the local disk, which ImageIO reads as it needs it instead of
    /// the whole file being read into memory first.
    internal static func decode(
        contentsOf url: URL,
        minimumDelay: Double = 0.08,
        largestSide: Int = largestSide,
        pixelLimit: Double = pixelLimit,
        memoryLimit: Int = animationMemoryLimit,
        cancellation: CancellationFlag = CancellationFlag(),
        firstFrame: ((DecodedImage) -> Void)? = nil
    ) -> DecodedImage? {
        decode(
            CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            minimumDelay: minimumDelay,
            largestSide: largestSide,
            pixelLimit: pixelLimit,
            memoryLimit: memoryLimit,
            cancellation: cancellation,
            firstFrame: firstFrame
        )
    }

    /// With `firstFrame`, an animation's first frame is handed over as soon as it is decoded,
    /// before the other frames are.
    ///
    /// Nil also without a source (a file that cannot be opened).
    private static func decode(
        _ source: CGImageSource?,
        minimumDelay: Double,
        largestSide: Int,
        pixelLimit: Double,
        memoryLimit: Int,
        cancellation: CancellationFlag,
        firstFrame: ((DecodedImage) -> Void)?
    ) -> DecodedImage? {
        guard let source, CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        var count = CGImageSourceGetCount(source)
        // Only a file that is an animation plays as one; the images of an icon file, a TIFF of
        // several pages or a collection are alternatives or pages, and the biggest is shown.
        var first = 0
        if count > 1 {
            if isAnimation(source) {
                // Every frame is checked for size below.
            } else {
                first = largestImage(in: source)
                count = first + 1
            }
        }
        let properties = properties(of: source, at: first)
        var width = number(kCGImagePropertyPixelWidth, in: properties)
        var height = number(kCGImagePropertyPixelHeight, in: properties)
        guard width * height <= pixelLimit else {
            return nil
        }
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
        }
        let options = thumbnailOptions(width: width, height: height, largestSide: largestSide)
        var frames: [(CGImage, Double)] = []
        var memory = 0
        var dropped = 0
        for index in first..<count {
            guard !cancellation.isCancelled else {
                return nil
            }
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                continue
            }
            memory += frame.bytesPerRow * frame.height
            frames.append((frame, max(minimumDelay, delay(of: source, at: index))))
            if index == first {
                if width <= 0 || height <= 0 { (width, height) = (Double(frame.width), Double(frame.height)) }
                if count - first > 1 {
                    firstFrame?(
                        DecodedImage(
                            frames: [(image: frame, delay: frames[0].1)],
                            pixelSize: CGSize(width: width, height: height)
                        )
                    )
                }
            }
            if memory > memoryLimit {
                dropped = count - index - 1
                break
            }
        }
        guard !frames.isEmpty else {
            return nil
        }
        return DecodedImage(
            frames: frames.map { (image: $0.0, delay: $0.1) },
            pixelSize: CGSize(width: width, height: height),
            framesDropped: dropped
        )
    }

    /// How the frames are made: turned, at most `largestSide` pixels on a side.
    private static func thumbnailOptions(width: Double, height: Double, largestSide: Int) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // A picture whose size is not named (a PDF) is made at its own size, not as one pixel.
        if width > 0, height > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(1, min(largestSide, Int(max(width, height))))
        }
        return options
    }

    /// Whether the frames of the source are those of an animation: a GIF, an animated PNG or
    /// WebP, or a HEIC sequence says so with a dictionary of its own.
    private static func isAnimation(_ source: CGImageSource) -> Bool {
        let properties = properties(of: source, at: 0)
        let containers = dictionary(CGImageSourceCopyProperties(source, nil))
        let keys: [CFString] = [
            kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary,
            kCGImagePropertyWebPDictionary
        ]
        // An animation names a delay or a loop count (a PNG dictionary alone is not one).
        let names: [CFString] = [
            kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyAPNGDelayTime,
            kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyGIFLoopCount, kCGImagePropertyAPNGLoopCount
        ]
        return keys.contains { key in
            guard let values = properties[key] as? [CFString: Any] ?? containers[key] as? [CFString: Any] else {
                return false
            }
            // A HEIC sequence or a WebP is one whatever it names.
            return key == kCGImagePropertyHEICSDictionary || key == kCGImagePropertyWebPDictionary
                || names.contains { values[$0] != nil }
        }
    }

    /// The index of the image with the most pixels.
    private static func largestImage(in source: CGImageSource) -> Int {
        var best = 0
        var area = -1.0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = properties(of: source, at: index)
            let size =
                number(kCGImagePropertyPixelWidth, in: properties) * number(kCGImagePropertyPixelHeight, in: properties)
            if size > area {
                best = index
                area = size
            }
        }
        return best
    }

    /// The properties of image `index` of `source`; none for an image it does not have.
    internal static func properties(of source: CGImageSource, at index: Int) -> [CFString: Any] {
        dictionary(CGImageSourceCopyPropertiesAtIndex(source, index, nil))
    }

    /// The keys and values of a dictionary of properties; none for none.
    private static func dictionary(_ properties: CFDictionary?) -> [CFString: Any] {
        properties as? [CFString: Any] ?? [:]
    }

    /// A number among `properties`; 0 when it is not there (a PDF names no size in pixels).
    internal static func number(_ key: CFString, in properties: [CFString: Any]) -> Double {
        (properties[key] as? NSNumber)?.doubleValue ?? 0
    }

    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = properties(of: source, at: index)
        for (dictionary, unclamped, clamped) in [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        ] {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            if let delay = (values[unclamped] as? NSNumber)?.doubleValue ?? (values[clamped] as? NSNumber)?.doubleValue
            {
                return delay
            }
        }
        return 0.1
    }
}

/// The frame scaled to the size it is shown at, so that scrolling and resizing a large image do
/// not resample all of it again at every draw.
///
/// One bitmap is kept (the one for the frame, size and scale in use), made in the background; it is
/// dropped when any of them changes. Only a frame that is shown smaller than it is gets one (an
/// enlarged one is no smaller to keep), and none above `pixelLimit` pixels. Main thread only.
@MainActor
internal final class ScaledFrameCache {
    private struct Key: Equatable {
        var frame: ObjectIdentifier
        var width: Int
        var height: Int
    }

    /// Guarded by `lock`.
    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var number = 0

        var value: Int {
            get {
                lock.lock()
                defer { lock.unlock() }
                return number
            }
            set {
                lock.lock()
                number = newValue
                lock.unlock()
            }
        }
    }

    /// A scaled bitmap has at most this many pixels (160 MB).
    internal static let pixelLimit = 40_000_000
    /// How long a size must stay before its bitmap is made.
    internal static let settle = 0.1

    private var key: Key?
    private var ready: CGImage?
    /// Counts the starts of a bitmap, so the result of an earlier one is dropped.
    private var generation = 0 { didSet { latest.value = generation } }
    /// The count, readable on the queue: a bitmap that was asked for and then replaced is not made.
    private let latest = Latest()
    /// One bitmap is made at a time, on a queue of its own (a zoom asks for dozens of sizes in a
    /// second; at most one resample of up to 160 MB runs, and the ones that are overtaken do not).
    internal let queue = DispatchQueue(label: "viewer.scale", qos: .userInitiated)
    /// How many bitmaps were made (for tests).
    internal private(set) var made = 0
    /// Called when a bitmap is ready for the key last asked for.
    internal var onReady: () -> Void = {}

    /// `frame` resampled to `width` × `height` pixels with the best interpolation.
    nonisolated internal static func scale(_ frame: CGImage, width: Int, height: Int) -> CGImage? {
        let space = frame.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The bitmap of `frame` at `width` × `height` pixels when it is there; else nil, and it is
    /// made in the background when `building` and the frame is shown smaller than it is.
    internal func image(for frame: CGImage, width: Int, height: Int, building: Bool = true) -> CGImage? {
        let wanted = Key(frame: ObjectIdentifier(frame), width: width, height: height)
        if key == wanted {
            return ready
        }
        guard building, width > 0, height > 0, width * height < frame.width * frame.height * 9 / 10,
            width * height <= Self.pixelLimit
        else {
            return nil
        }
        key = wanted
        ready = nil
        generation += 1
        let token = generation
        let latest = latest
        queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            // Overtaken while it waited: another size is wanted now.
            guard latest.value == token else {
                return
            }
            let scaled = autoreleasepool { Self.scale(frame, width: width, height: height) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == token else {
                    return
                }
                ready = scaled
                made += 1
                if scaled != nil { onReady() }
            }
        }
        return nil
    }

    /// Forgets the bitmap and any that is being made.
    internal func invalidate() {
        key = nil
        ready = nil
        generation += 1
    }
}

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
            let turned = quarterTurns % 2 != 0
            let size = turned ? CGSize(width: imageRect.height, height: imageRect.width) : imageRect.size
            let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            // Scrolling and drawing again take the bitmap made for this size; while it is made, and
            // while an animation or the window's edge changes the picture, the frame is resampled.
            let scale = window?.backingScaleFactor ?? 1
            if let bitmap = scaled.image(
                for: frameImage,
                width: Int((size.width * scale).rounded()),
                height: Int((size.height * scale).rounded()),
                building: !isAnimated && !inLiveResize
            ) {
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
    internal var fit = ImageFit.none {
        didSet {
            manualZoom = nil
            arrange()
        }
    }
    internal var centered = false { didSet { arrange() } }
    /// Called when the zoom factor changed.
    internal var onZoomChange: () -> Void = {}

    /// The image as it is shown now, for printing.
    internal var currentFrame: CGImage? { image?.frames[frameIndex].image }
    internal var imageSize: CGSize { image?.pixelSize ?? .zero }
    internal var isDownsampled: Bool { image?.isDownsampled ?? false }
    /// The number of frames of an animation that were left out for want of memory.
    internal var framesDropped: Int { image?.framesDropped ?? 0 }
    internal var frameCount: Int { image?.frames.count ?? 0 }

    /// The size of the turned image at 100 %, in points: one pixel of the image on one pixel
    /// of the screen.
    private var turnedSize: CGSize {
        guard let size = image?.size else {
            return .zero
        }
        let scale = Self.pixelsPerPoint(window: window, screen: NSScreen.main)
        return quarterTurns % 2 != 0
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
        guard size.width > 0, size.height > 0, fit != .none else {
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

    internal func setZoom(_ factor: CGFloat) {
        manualZoom = min(64, max(0.01, factor))
        arrange()
    }

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
        timer = Timer.scheduledTimer(withTimeInterval: image.frames[frameIndex].delay, repeats: false) {
            [weak self] _ in
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
