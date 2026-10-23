import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The bitmap an image is drawn from when it is shown smaller than it is.
@MainActor
@Suite
internal struct ViewerAdoptImageTests {
    /// Counts what a callback was called for.
    internal final class Counter {
        /// How often it was called.
        internal var count = 0

        deinit {
            // Nothing to release.
        }
    }

    /// A picture of the size, red in its left half and blue in its right one.
    private func picture(_ width: Int, _ height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        // Red on the left half, blue on the right (the drawing has its origin at the bottom left).
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }

    /// Returns once everything the cache's queue held has run and its results have reached the main thread.
    private func settled(_ cache: ScaledFrameCache) async {
        await settled(cache.queue)
    }

    /// Returns once everything the queue held has run and what it sent to the main thread has arrived.
    private func settled(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        for _ in 0..<5 { await Task.yield() }
    }

    /// Waits until the condition holds or the tests' ceiling has passed; returns whether it holds.
    private func wait(until condition: () -> Bool) async -> Bool {
        // Generous: other tests that run on the main actor at the same time hold it for as long as they take, and
        // the wait costs nothing once the condition holds.
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 3_000_000) }
        return condition()
    }

    /// A frame is scaled once, off the main thread, for the size it is shown at; other sizes, a new frame and an
    /// invalidation are handled without needless bitmaps.
    @Test
    internal func aFrameIsScaledOnceForTheSizeItIsShownAt() async throws {
        let frame = try picture(2_000, 1_000)
        let cache = ScaledFrameCache()
        let ready = Counter()
        cache.onReady = { ready.count += 1 }
        #expect(cache.image(for: frame, width: 500, height: 250) == nil)
        #expect(await wait { cache.made == 1 })
        let scaled = try #require(cache.image(for: frame, width: 500, height: 250))
        #expect(scaled.width == 500 && scaled.height == 250 && ready.count == 1)
        // Drawing again and again takes the same bitmap, however often.
        for _ in 0..<50 { #expect(cache.image(for: frame, width: 500, height: 250) === scaled) }
        #expect(cache.made == 1)
        // Another size: nothing is made while the window's edge moves, and one bitmap after.
        #expect(cache.readyImage(for: frame, width: 400, height: 200) == nil && cache.made == 1)
        #expect(cache.image(for: frame, width: 400, height: 200) == nil)
        #expect(await wait { cache.made == 2 })
        #expect(cache.image(for: frame, width: 400, height: 200)?.width == 400)
        #expect(cache.readyImage(for: frame, width: 400, height: 200)?.width == 400)
        // Showing it larger than it is, or at nearly its own size, needs no bitmap; nor does a huge one.
        #expect(
            cache.image(for: frame, width: 3_000, height: 1_500) == nil
                && cache.image(for: frame, width: 1_990, height: 995) == nil
        )
        let big = try picture(8_000, 6_000)
        #expect(cache.image(for: big, width: 7_000, height: 5_800) == nil)
        await settled(cache)
        #expect(cache.made == 2)
        // A new frame, or an invalidation, drops the bitmap.
        let other = try picture(2_000, 1_000)
        cache.queue.suspend()
        #expect(cache.image(for: other, width: 400, height: 200) == nil)
        cache.invalidate()
        cache.queue.resume()
        await settled(cache)
        #expect(cache.made == 2)
        #expect(cache.readyImage(for: other, width: 400, height: 200) == nil)
    }

    /// A scaled frame keeps its colors, and its left and right sides where they were.
    @Test
    internal func aScaledFrameKeepsItsColorsAndSides() throws {
        let scaled = try #require(ScaledFrameCache.scale(try picture(1_000, 500), width: 100, height: 50))
        #expect(scaled.width == 100 && scaled.height == 50)
        let rep = NSBitmapImageRep(cgImage: scaled)
        let left = try #require(rep.colorAt(x: 10, y: 25)?.usingColorSpace(.sRGB))
        let right = try #require(rep.colorAt(x: 90, y: 25)?.usingColorSpace(.sRGB))
        #expect(
            left.redComponent > 0.9 && left.blueComponent < 0.1 && right.blueComponent > 0.9 && right.redComponent < 0.1
        )
    }

    /// A large image in the canvas is resampled once and drawn from that bitmap however often it is drawn again; a
    /// turn makes one new bitmap.
    @Test
    internal func aLargeImageIsResampledOnceWhileItIsScrolledAndDrawnAgain() async throws {
        let frame = try picture(4_000, 2_000)
        let view = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.fit = .window
        view.show(DecodedImage(frames: [(image: frame, delay: 0.1)], pixelSize: CGSize(width: 4_000, height: 2_000)))
        view.layoutSubtreeIfNeeded()
        func drawn() throws -> NSBitmapImageRep {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        func sides(_ rep: NSBitmapImageRep) -> (red: Bool, blue: Bool) {
            // The image fits the width: red in the left half, blue in the right one.
            let row = rep.pixelsHigh / 4
            let left = rep.colorAt(x: rep.pixelsWide / 8, y: row)?.usingColorSpace(.sRGB)
            let right = rep.colorAt(x: rep.pixelsWide * 7 / 8, y: row)?.usingColorSpace(.sRGB)
            return (
                (left?.redComponent ?? 0) > 0.9 && (left?.blueComponent ?? 1) < 0.1,
                (right?.blueComponent ?? 0) > 0.9 && (right?.redComponent ?? 1) < 0.1
            )
        }
        // The queue stands still while the sizes are asked for: only the last one is made, however long that takes.
        view.scalingQueue.suspend()
        let before = sides(try drawn())
        #expect(before.red && before.blue, "drawn from the frame")
        view.scalingQueue.resume()
        await settled(view.scalingQueue)
        #expect(await wait { view.scaledBitmapsMade == 1 })
        for _ in 0..<5 {
            let after = sides(try drawn())
            #expect(after.red && after.blue, "drawn from the bitmap")
        }
        #expect(view.scaledBitmapsMade == 1)
        // Turned: the bitmap is for the same size turned about, the picture follows.
        view.scalingQueue.suspend()
        view.rotate(by: 1)
        _ = try drawn()
        view.scalingQueue.resume()
        await settled(view.scalingQueue)
        #expect(await wait { view.scaledBitmapsMade == 2 })
        _ = try drawn()
        #expect(view.scaledBitmapsMade == 2)
    }
}
