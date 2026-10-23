import AFMKernel
import CoreGraphics
import Foundation
import ImageIO

/// Decodes images with ImageIO, within limits of size, pixels and memory.
///
/// A value made where it is used, with the limits it decodes within; `decode` is meant for a background thread and
/// touches nothing shared.
internal struct ImageDecoder {
    /// No side of a decoded frame is longer than this: an image of several hundred megapixels
    /// is downsampled while it is decoded and never exists at full size in memory.
    internal static let largestSide = 8_192
    /// The frames of an animation may take this much memory together; the rest is left out.
    internal static let animationMemoryLimit = 512 << 20
    /// An image of more pixels than this is not decoded (a file that claims billions of pixels
    /// in a few kilobytes would take the memory of the computer to decode).
    internal static let pixelLimit = 400_000_000.0

    /// The shortest time a frame of an animation stays, in seconds (the specification's `GifMinDelay`).
    internal var minimumDelay = 0.08
    /// No side of a decoded frame is longer than this many pixels.
    internal var largestSide = Self.largestSide
    /// An image of more pixels than this is not decoded.
    internal var pixelLimit = Self.pixelLimit
    /// The bytes the frames of an animation may take together.
    internal var memoryLimit = Self.animationMemoryLimit
    /// Set, it ends the decoding before the next frame, and `decode` returns nil.
    internal var cancellation = CancellationFlag()
    /// Receives an animation's first frame as soon as it is decoded, before the other frames are (on the thread
    /// that decodes).
    internal var firstFrame: ((DecodedImage) -> Void)?

    /// The properties of image `index` of `source`; none for an image it does not have.
    internal static func properties(of source: CGImageSource, at index: Int) -> [CFString: Any] {
        dictionary(CGImageSourceCopyPropertiesAtIndex(source, index, nil))
    }

    /// A number among `properties`; 0 when it is not there (a PDF names no size in pixels).
    internal static func number(_ key: CFString, in properties: [CFString: Any]) -> Double {
        properties[key] as? Double ?? 0
    }

    /// How the frames are made: turned, at most `largestSide` pixels on a side.
    private static func thumbnailOptions(for size: CGSize, largestSide: Int) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // A picture whose size is not named (a PDF) is made at its own size, not as one pixel.
        if size.width > 0, size.height > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(1, min(largestSide, Int(max(size.width, size.height))))
        }
        return options
    }

    /// The size in pixels the properties of an image name, turned as a photo's EXIF orientation says.
    private static func pixelSize(in properties: [CFString: Any]) -> CGSize {
        let width = number(kCGImagePropertyPixelWidth, in: properties)
        let height = number(kCGImagePropertyPixelHeight, in: properties)
        // Orientations 5 to 8 turn the picture by a quarter.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The images of the source that are shown: every frame of an animation, or the biggest one.
    ///
    /// Only a file that is an animation plays as one; the images of an icon file, a TIFF of
    /// several pages or a collection are alternatives or pages.
    private static func shownImages(of source: CGImageSource) -> Range<Int> {
        let count = CGImageSourceGetCount(source)
        guard count > 1, !isAnimation(source) else {
            return 0..<count
        }
        let largest = largestImage(in: source)
        return largest..<largest + 1
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

    /// The keys and values of a dictionary of properties; none for none.
    private static func dictionary(_ properties: CFDictionary?) -> [CFString: Any] {
        properties as? [CFString: Any] ?? [:]
    }

    /// The seconds frame `index` of an animated GIF or PNG stays; 0.1 when it names none.
    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = properties(of: source, at: index)
        for (dictionary, unclamped, clamped) in [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        ] {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            if let delay = values[unclamped] as? Double ?? values[clamped] as? Double {
                return delay
            }
        }
        return 0.1
    }

    /// Nil when the data is no image ImageIO can read, or it is cancelled.
    ///
    /// Photos are turned as their EXIF orientation says.
    internal func decode(_ data: Data) -> DecodedImage? {
        decode(source: CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    /// The same for a file on the local disk, which ImageIO reads as it needs it instead of
    /// the whole file being read into memory first.
    internal func decode(contentsOf url: URL) -> DecodedImage? {
        decode(source: CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    /// Nil also without a source (a file that cannot be opened), and for an image of more than `pixelLimit` pixels.
    private func decode(source: CGImageSource?) -> DecodedImage? {
        guard let source, CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let images = Self.shownImages(of: source)
        let size = Self.pixelSize(in: Self.properties(of: source, at: images.lowerBound))
        guard size.width * size.height <= pixelLimit else {
            return nil
        }
        return decodeFrames(images, of: source, pixelSize: size)
    }

    /// Decodes the frames `images` of `source` until they take `memoryLimit` bytes; nil when none can be decoded.
    ///
    /// `pixelSize` is that of the first image; when it names none (a PDF), the first frame's is taken.
    private func decodeFrames(_ images: Range<Int>, of source: CGImageSource, pixelSize: CGSize) -> DecodedImage? {
        let options = Self.thumbnailOptions(for: pixelSize, largestSide: largestSide)
        var size = pixelSize
        var frames: [(image: CGImage, delay: Double)] = []
        var memory = 0
        var dropped = 0
        for index in images {
            guard !cancellation.isCancelled else {
                return nil
            }
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                continue
            }
            memory += frame.bytesPerRow * frame.height
            frames.append((image: frame, delay: max(minimumDelay, Self.delay(of: source, at: index))))
            if index == images.lowerBound {
                if size.width <= 0 || size.height <= 0 { size = CGSize(width: frame.width, height: frame.height) }
                if images.count > 1 { firstFrame?(DecodedImage(frames: frames, pixelSize: size)) }
            }
            if memory > memoryLimit {
                dropped = images.upperBound - index - 1
                break
            }
        }
        guard !frames.isEmpty else {
            return nil
        }
        return DecodedImage(frames: frames, pixelSize: size, framesDropped: dropped)
    }
}
