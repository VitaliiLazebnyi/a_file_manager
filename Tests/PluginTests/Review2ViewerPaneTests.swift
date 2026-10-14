import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import ImageIO
import TestSupport
import Testing
import UniformTypeIdentifiers
@testable import ViewerPlugin

/// Review round 2, the pane and its views on the main thread: nothing waits for a server, a page
/// leads nowhere, a text that is no longer read keeps what it shows, images are made once.
@MainActor @Suite(.serialized) struct Review2ViewerPane {
    let memory = MemoryFileSystem()
    let hook = Review2HookProvider()
    let plugin: ViewerPlugin
    let bench: TestBench

    init() throws {
        _ = NSApplication.shared
        plugin = ViewerPlugin(overlayHost: { _ in nil }, quickViewDelay: 0.01, showsWindows: false)
        bench = TestBench(plugins: [plugin], fileSystems: [memory, hook], left: memory.url("/A"), right: memory.url("/B"))
        memory.addFile("/A/small.txt", "small file\nsecond line")
        memory.addFile("/A/index.html", "<html><body><a href=\"next.html\">next</a></body></html>")
        memory.addFile("/A/next.html", "<html><body>next page</body></html>")
    }

    @discardableResult
    func wait(upTo seconds: TimeInterval = 300, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        return condition()
    }

    private func pane() -> ViewerPane {
        ViewerPane(kernel: bench.kernel, settings: ListerSettings(bench.kernel.settings), temporaryCopies: TemporaryCopies(), isEmbedded: true)
    }

    // MARK: Nothing waits for the server

    @Test func stoppingThePaneDoesNotWaitForTheReadersOfAServerToClose() async throws {
        hook.contents["/slow.txt"] = Data(String(repeating: "a line of text\n", count: 2000).utf8)
        let gate = DispatchSemaphore(value: 0)
        hook.onClose = { _ = gate.wait(timeout: .now() + 30) }
        let pane = pane()
        pane.load(ViewerItem(source: .file(URL(string: "hook:///slow.txt")!), title: "slow"))
        #expect(await wait { pane.loaded != nil && pane.pager.document?.isIndexComplete == true })
        let started = Date()
        pane.stopWork()
        pane.load(ViewerItem(source: .file(memory.url("/A/small.txt")), title: "small"))
        let elapsed = Date().timeIntervalSince(started)
        // The closes wait on the gate for 30 seconds: the main thread did not.
        #expect(elapsed < 10, "stopWork took \(elapsed) s")
        gate.signal()
        for _ in 0..<64 { gate.signal() }
        pane.stopWork()
        ViewerCleanup.drain()
    }

    // MARK: The text that is no longer read

    @Test func aTextThatIsNoLongerReadKeepsWhatItShowsWhenScrolled() async throws {
        let pane = pane()
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 200)
        memory.addFile("/A/many.txt", (1...2000).map { "line number \($0)" }.joined(separator: "\n"))
        pane.load(ViewerItem(source: .file(memory.url("/A/many.txt")), title: "many"))
        #expect(await wait { pane.pager.document?.isIndexComplete == true && pane.pager.position != nil })
        pane.stopWork()
        #expect(!pane.pager.isIndexing)
        // Scrolling now fetches nothing, and the rows on screen are not blanked by the fetch that was stopped.
        pane.pager.perform(.pageDown)
        pane.pager.perform(.pageDown)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(pane.pager.document != nil && pane.pager.position != nil)
    }

    // MARK: Links in the page

    @Test func aLinkInAPageLeadsOnlyToFilesBesideIt() async throws {
        let pane = pane()
        pane.load(ViewerItem(source: .file(memory.url("/A/index.html")), title: "index"))
        #expect(await wait { pane.loaded != nil })
        let shown = pane.item?.url
        for text in ["sftp://evil/x", "ftp://evil/x", "smb://evil/share", "file:///etc/passwd", "../outside.html", "..%2F..%2Fx"] {
            pane.followLink(URL(string: text)!)
            #expect(pane.item?.url == shown, "\(text)")
        }
        pane.followLink(URL(string: "next.html")!)
        #expect(await wait { pane.item?.url?.lastPathComponent == "next.html" })
        pane.stopWork()
    }

    // MARK: Big documents

    @Test func aHugeHTMLFileIsNotLaidOutAsAPageOnTheMainThread() async throws {
        let pane = pane()
        var html = Data("<html><body>".utf8)
        let line = Data(String(repeating: "<p>paragraph of the page</p>\n", count: 1000).utf8)
        while html.count < Int(ViewerPane.htmlPageLimit) + (1 << 20) { html.append(line) }
        let writer = try memory.write(memory.url("/A/huge.html"))
        try writer.write(html)
        try writer.close(attributes: FileAttributes())
        pane.load(ViewerItem(source: .file(memory.url("/A/huge.html")), title: "huge"))
        #expect(await wait(upTo: 60) { pane.loaded != nil })
        pane.setMode(.media)
        // The page is not made: the text modes show it.
        #expect(await wait(upTo: 60) { pane.mode.isTextual && pane.pager.document != nil && pane.webView == nil })
        pane.stopWork()
    }

    @Test func aHugeRTFFileIsNotFormattedOnTheMainThread() async throws {
        let pane = pane()
        var rtf = Data("{\\rtf1\\ansi ".utf8)
        let line = Data(String(repeating: "word ", count: 2000).utf8)
        while rtf.count < Int(ViewerPane.rtfLimit) + (1 << 20) { rtf.append(line) }
        rtf.append(Data("}".utf8))
        let writer = try memory.write(memory.url("/A/huge.rtf"))
        try writer.write(rtf)
        try writer.close(attributes: FileAttributes())
        pane.load(ViewerItem(source: .file(memory.url("/A/huge.rtf")), title: "huge rtf"))
        #expect(await wait(upTo: 60) { pane.loaded != nil && (pane.mode.isTextual ? pane.pager.document != nil : pane.richText != nil || pane.webView != nil) })
        #expect(pane.richText == nil)
        pane.stopWork()
    }

    // MARK: Images

    private func picture(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func aZoomThatPassesThroughManySizesMakesOneBitmap() async throws {
        let frame = try picture(2000, 1000)
        let cache = ScaledFrameCache()
        // The queue stands still while the sizes are asked for, so how fast this loop runs on a busy
        // machine decides nothing: every size but the last has been overtaken when the queue goes on.
        cache.queue.suspend()
        for step in 0..<40 { _ = cache.image(for: frame, width: 600 + step * 5, height: 300 + step * 2) }
        let last = (width: 600 + 39 * 5, height: 300 + 39 * 2)
        cache.queue.resume()
        #expect(await wait { cache.made >= 1 })
        // Whatever else is still to come has to pass the queue the bitmap came through.
        await withCheckedContinuation { continuation in cache.queue.async { continuation.resume() } }
        for _ in 0..<5 { await Task.yield() }
        #expect(cache.made == 1)
        #expect(cache.image(for: frame, width: last.width, height: last.height)?.width == last.width)
    }

    private func encoded(_ images: [CGImage], type: UTType, properties: [CFString: Any] = [:], frameProperties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil))
        if !properties.isEmpty { CGImageDestinationSetProperties(destination, properties as CFDictionary) }
        for image in images { CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func theImagesOfAnIconOrAMultiPageTIFFAreNotPlayedAsAnAnimation() throws {
        let tiff = try encoded([try picture(64, 64), try picture(300, 200), try picture(128, 128)], type: .tiff)
        let still = try #require(ImageDecoder.decode(tiff))
        #expect(still.frames.count == 1 && still.frames[0].image.width == 300 && still.frames[0].image.height == 200)
    }

    @Test func aGIFWithSeveralFramesIsStillAnAnimation() throws {
        let gif = try encoded([try picture(20, 20), try picture(20, 20), try picture(20, 20)], type: .gif,
                              properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
                              frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]])
        let animation = try #require(ImageDecoder.decode(gif, minimumDelay: 0.05))
        #expect(animation.frames.count == 3)
    }

    // MARK: Row text

    @Test func linksAndTextOfHTMLThatHasLoneAngleBrackets() {
        let result = HTMLText.plainText(from: "<p>if a < b then c</p><p>done</p>")
        #expect(result.text == "if a < b then c\ndone\n", "\(result.text.debugDescription)")
        // A lone `<` at the very end does not drop the rest of the document before it.
        #expect(HTMLText.plainText(from: "kept text <").text == "kept text <\n")
        let links = HTMLText.plainText(from: "<a data-href=\"decoy\" href=\"real\">x</a> <a title=\"a>b\" href=\"two\">y</a> <a title='href=\"nope\"' href=three>z</a>")
        #expect(links.links == ["real", "two", "three"], "\(links.links)")
    }
}
