import CoreGraphics
import Foundation

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

    /// A scaled bitmap has at most this many pixels (160 MB).
    internal static let pixelLimit = 40_000_000
    /// How long a size must stay before its bitmap is made.
    internal static let settle = 0.1

    private var key: Key?
    private var ready: CGImage?
    /// Counts the starts of a bitmap, so the result of an earlier one is dropped.
    private var generation = 0 { didSet { latest.value = generation } }
    /// The count, readable on the queue: a bitmap that was asked for and then replaced is not made.
    private let latest = LatestNumber()
    /// One bitmap is made at a time, on a queue of its own (a zoom asks for dozens of sizes in a
    /// second; at most one resample of up to 160 MB runs, and the ones that are overtaken do not).
    internal let queue = DispatchQueue(label: "viewer.scale", qos: .userInitiated)
    /// How many bitmaps were made (for tests).
    internal private(set) var made = 0
    /// Called when a bitmap is ready for the key last asked for.
    internal var onReady: () -> Void = {
        // Nothing waits for a bitmap until a view says what to redraw.
    }

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

    /// The bitmap of `frame` at `width` × `height` pixels when it is there, else nil; nothing is made.
    internal func readyImage(for frame: CGImage, width: Int, height: Int) -> CGImage? {
        key == Key(frame: ObjectIdentifier(frame), width: width, height: height) ? ready : nil
    }

    /// The bitmap of `frame` at `width` × `height` pixels when it is there; else nil, and it is
    /// made in the background when the frame is shown smaller than it is.
    internal func image(for frame: CGImage, width: Int, height: Int) -> CGImage? {
        let wanted = Key(frame: ObjectIdentifier(frame), width: width, height: height)
        if key == wanted {
            return ready
        }
        guard width > 0, height > 0, width * height < frame.width * frame.height * 9 / 10,
            width * height <= Self.pixelLimit
        else {
            return nil
        }
        key = wanted
        ready = nil
        generation += 1
        let token = generation
        let counter = latest
        queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            // Overtaken while it waited: another size is wanted now.
            guard counter.value == token else {
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

    deinit {
        // Nothing to release.
    }
}
