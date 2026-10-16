import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// HTML as text, made fast without changing what comes out, and the bitmap an image is
/// drawn from.
@Suite struct ViewerAdoptHTML {
    private func random(_ seed: UInt64) -> (Int) -> Int {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return { bound in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(truncatingIfNeeded: state >> 11) % max(1, bound)
        }
    }

    private let pieces: [String] = [
        "text ", "More  words\n", "tab\there ", "\u{A0}", "\u{2003}", "\u{85}", " ", "  \n  ", "\r\n", "x", "é", "日本語 ",
        "😀", "caf\u{E9} ",
        "&amp;", "&lt;", "&gt;", "&quot;", "&apos;", "&nbsp;", "&copy;", "&#65;", "&#x41;", "&#xZZ;", "&#0;",
        "&#xD800;", "&unknown;", "&amp", "&", "&;", "&#;", "&eacute;&auml;",
        "&longentitynamethatisfartoolong;", "&a<b>;",
        "<p>", "</p>", "<div>", "</div>", "<br>", "<br/>", "<li>", "<ul>", "<ol>", "<table>", "<tr>", "<h1>", "</h1>",
        "<H2>", "<hr>", "<title>", "<dt>", "<blockquote>",
        "<pre>", "</pre>", "<PRE>", "<b>", "</b>", "<i class=\"x\">", "<span>", "<em>", "<h7>", "<p/>",
        "<a href=\"x\">", "<a href='y&amp;z'>", "<A HREF=u>", "<a href = \"w\">", "<a data-href=\"q\">",
        "<a href=\"\">", "<a href=\"#frag\">", "<a>", "<a name=\"n\">",
        "<a title=\"t\" href=\"https://example.com/?a=1&amp;b=2&c=3\" class=\"k\">", "<a\nhref=\"multi\nline\">",
        "<a\r\nhref=\"crlf\r\nvalue\">", "<a href=\"ü&euro;\">",
        "<a href='&#65;&#x42;&bogus;&amp'>", "<a href=\"a&amp;b&amp;c&amp;d&amp;e&amp;f&gt;&lt;&quot;&nbsp;\">",
        "<a href=value-with-dash/and&amp;more>", "<a href=\"x\" href=\"y\">",
        "<a href=\"日本語\">", "<a href=\"x\u{301}\">", "<a href=\"&;&&amp;;\">", "<a href=\"unterminated>", "</a>",
        "</A>",
        "<!-- comment -->", "<!-- <p>hidden</p> -->", "<!---->", "<!-->", "<!DOCTYPE html>", "<?xml version=\"1.0\"?>",
        "<script>var a = '<b>';</script>", "<SCRIPT type=text/javascript>x</Script>", "<style>p { color: red }</style>",
        "<svg><path d=\"M0\"/></svg>", "<noscript>no</noscript>",
        "<template><p>t</p></template>", "</script>", "<script src=x></script>", "< b>", "<>", "</>", "<3", "a < b",
        "x > y", "<<p>>", "<a b c>", "<verylongtagnamethatgoesonforever>",
        "<h1 attr=\"v\"", "<div class='a>b'>"
    ]

    private func generate(_ next: (Int) -> Int, count: Int) -> [UInt16] {
        var units: [UInt16] = []
        for _ in 0..<count {
            switch next(40) {
            case 0: units.append(UInt16(0xD800 + next(0x400)))
            case 1: units.append(UInt16(0xDC00 + next(0x400)))
            case 2: units.append(UInt16(next(0x20)))
            default: units.append(contentsOf: pieces[next(pieces.count)].utf16)
            }
        }
        return units
    }

    @Test func theFastScanGivesTheOutputOfTheUnitByUnitOne() {
        var compared = 0
        for seed in 1...400 as ClosedRange<UInt64> {
            let next = random(seed)
            var units = generate(next, count: 1 + next(60))
            // Cut anywhere, as a file can end in the middle of a tag or an entity.
            if seed % 5 == 0 { units.removeLast(min(units.count, next(12))) }
            for braces in [true, false] {
                let fast = HTMLText.plainText(units: units, linkBraces: braces)
                let reference = HTMLReference.plainText(units: units, linkBraces: braces)
                #expect(
                    fast == reference,
                    Comment(
                        rawValue:
                            "seed \(seed), braces \(braces): \(String(decoding: units, as: UTF16.self).debugDescription)"
                    )
                )
                compared += 1
            }
        }
        #expect(compared == 800)
    }

    @Test func theFastScanAgreesOnLongPagesToo() {
        for seed in 1_000...1_012 as ClosedRange<UInt64> {
            let next = random(seed)
            let units = generate(next, count: 4_000)
            #expect(HTMLText.plainText(units: units) == HTMLReference.plainText(units: units), "seed \(seed)")
            #expect(
                HTMLText.plainText(units: units, linkBraces: false)
                    == HTMLReference.plainText(units: units, linkBraces: false),
                "seed \(seed)"
            )
        }
    }

    @Test func linksAreFoundTheSameWayInEveryFormOfTheAttribute() {
        let html = """
            <a href="one">1</a> <A HREF='two&amp;2'>2</A> <a href=three>3</a> <a class=x href = "four">4</a> <a data-href="five">5</a> <a href="#six">6</a>
            <a href="">7</a> <a href="https://e.com/?a=1&amp;b=2&amp;c&amp">8</a> <a title='a href="nested"' href="real">9</a> <a href="ü">10</a>
            """
        let result = HTMLText.plainText(units: Array(html.utf16))
        #expect(result == HTMLReference.plainText(units: Array(html.utf16)))
        // `data-href` is no `href`, and the text `href="nested"` inside the title of a tag is no attribute.
        #expect(result?.links == ["one", "two&2", "three", "four", "https://e.com/?a=1&b=2&c&amp", "real", "ü"])
    }
}

/// The bitmap an image is drawn from when it is shown smaller than it is.
@MainActor @Suite struct ViewerAdoptImage {
    private func picture(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
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

    private func settled(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        for _ in 0..<5 { await Task.yield() }
    }

    private func wait(until condition: () -> Bool) async -> Bool {
        // Generous: other tests that run on the main actor at the same time hold it for as long as they take, and
        // the wait costs nothing once the condition holds.
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 3_000_000) }
        return condition()
    }

    @Test func aFrameIsScaledOnceForTheSizeItIsShownAt() async throws {
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
        #expect(cache.image(for: frame, width: 400, height: 200, building: false) == nil && cache.made == 1)
        #expect(cache.image(for: frame, width: 400, height: 200) == nil)
        #expect(await wait { cache.made == 2 })
        #expect(cache.image(for: frame, width: 400, height: 200)?.width == 400)
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
        #expect(cache.image(for: other, width: 400, height: 200, building: false) == nil)
    }

    @Test func aScaledFrameKeepsItsColorsAndSides() throws {
        let scaled = try #require(ScaledFrameCache.scale(try picture(1_000, 500), width: 100, height: 50))
        #expect(scaled.width == 100 && scaled.height == 50)
        let rep = NSBitmapImageRep(cgImage: scaled)
        let left = try #require(rep.colorAt(x: 10, y: 25)?.usingColorSpace(.sRGB))
        let right = try #require(rep.colorAt(x: 90, y: 25)?.usingColorSpace(.sRGB))
        #expect(
            left.redComponent > 0.9 && left.blueComponent < 0.1 && right.blueComponent > 0.9 && right.redComponent < 0.1
        )
    }

    @Test func aLargeImageIsResampledOnceWhileItIsScrolledAndDrawnAgain() async throws {
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
            let y = rep.pixelsHigh / 4
            let left = rep.colorAt(x: rep.pixelsWide / 8, y: y)?.usingColorSpace(.sRGB)
            let right = rep.colorAt(x: rep.pixelsWide * 7 / 8, y: y)?.usingColorSpace(.sRGB)
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

private final class Counter {
    var count = 0
}
