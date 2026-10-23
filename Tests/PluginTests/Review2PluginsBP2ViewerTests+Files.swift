import AFMKernel
import AppKit
import Darwin
import Foundation
import ImageIO
import LocalFileSystemPlugin
import PDFKit
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import ViewerPlugin

/// Printing the whole text, links in RTF and PDF, the pixel limit, links whose target size is known,
/// the temporary copies at the end, and a FIFO that takes the place of a file.
extension Review2PluginsBP2ViewerTests {
    // MARK: A link whose target size the file system gave (L016)

    /// A file system with one entry, a link whose target size it knows, and no reader.
    private final class LinkProvider: FileSystemProvider {
        let scheme = "link"
        let capabilities: FileSystemCapabilities = []
        let entry: FileItem

        init(_ entry: FileItem) { self.entry = entry }

        func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }
        func parent(of _: URL) -> URL? { nil }
        func createDirectory(at _: URL) {
            // Nothing is made: the file system is read only.
        }

        func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("x") }
        func remove(_: URL) {
            // Nothing is removed: the file system is read only.
        }

        func move(_: URL, to _: URL, replacing _: Bool) {
            // Nothing is moved: the file system is read only.
        }

        func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) {
            // Nothing is copied: the file system is read only.
        }

        func item(at _: URL) -> FileItem? { entry }
        func read(_: URL) throws -> any FileReader {
            throw FileSystemError.notSupported("a link whose target size is known is not read to be measured")
        }

        deinit {
            // Nothing to release.
        }
    }

    // MARK: Printing (the whole text, to a page limit)

    /// Printing takes a long text in full up to the page limit, and a part of it when asked.
    @Test
    internal func printingCoversALongTextInFull() {
        // 40,000 lines of 50 bytes: 2 MB, which the old limit of 512 KB cut at a quarter.
        let line = String(repeating: "x", count: 49)
        let text = (1...40_000).map { _ in line }.joined(separator: "\n") + "\n"
        let doc = Indexing().document(Data(text.utf8), columns: 200)
        let all = ViewerPane.printableText(
            of: doc,
            in: doc.content,
            maxRows: ViewerPane.printPageLimit * 60,
            cancellation: CancellationFlag()
        )
        #expect(all.lines.count == 40_000 && !all.truncated)
        let cut = ViewerPane.printableText(of: doc, in: doc.content, maxRows: 1_200, cancellation: CancellationFlag())
        #expect(cut.lines.count == 1_200 && cut.truncated)
        let exact = ViewerPane.printableText(
            of: doc,
            in: doc.content,
            maxRows: 40_000,
            cancellation: CancellationFlag()
        )
        #expect(exact.lines.count == 40_000 && !exact.truncated)
        #expect(ViewerPane.printPageLimit >= 1_000)
        // A part of the text.
        let part = ViewerPane.printableText(
            of: doc,
            in: 0..<500,
            maxRows: ViewerPane.printPageLimit * 60,
            cancellation: CancellationFlag()
        )
        #expect(part.lines.count == 10 && part.text == String(repeating: line + "\n", count: 10))
    }

    /// The text for printing is laid out in pages of whole lines, and every page can be drawn.
    @MainActor
    @Test
    internal func theTextForPrintingIsDrawnPageByPage() throws {
        let lines = (1...130).map { "line \($0)" }
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let page = NSSize(width: 400, height: 300)
        let perPage = TextPrintView.linesPerPage(font: font, pageHeight: page.height)
        let view = TextPrintView(lines: lines, font: font, pageSize: page)
        #expect(perPage >= 10 && view.pageCount == (130 + perPage - 1) / perPage)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range == NSRange(location: 1, length: view.pageCount))
        let second = view.rectForPage(2)
        #expect(
            second.origin.y == CGFloat(perPage) * TextPrintView.lineHeight(of: font) && second.height <= page.height
        )
        // The last page holds what is left, and every page can be drawn.
        for number in 1...view.pageCount {
            let rect = view.rectForPage(number)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: rep)
        }
        // An empty text is one empty page.
        #expect(TextPrintView(lines: [], font: font, pageSize: page).pageCount == 1)
    }

    // MARK: Links in RTF and PDF (V021)

    /// Only web and mail links clicked in RTF and PDF are opened; every click is handled, so the
    /// views open nothing by themselves.
    @MainActor
    @Test
    internal func onlyWebAndMailLinksAreOpenedFromRTFAndPDF() throws {
        let links = CoverageViewerLinks()
        let gate = LinkGate(opener: links)
        let textView = NSTextView()
        // A URL as an Objective-C object, as AppKit may hand it over.
        let bridged: AnyObject = try #require(URL(string: "https://nsurl.example")) as AnyObject
        for link: Any in [
            try #require(URL(string: "https://example.com/a")), "http://example.org",
            try #require(URL(string: "mailto:me@example.com")), bridged
        ] {
            #expect(gate.textView(textView, clickedOnLink: link, at: 0))
        }
        for link: Any in [
            try #require(URL(string: "file:///etc/passwd")), "smb://server/share", try #require(URL(string: "afp://x")),
            "javascript:alert(1)", try #require(URL(string: "x-apple.systempreferences:")), 42
        ] {
            // Handled all the same: the text view does not open it by itself.
            #expect(gate.textView(textView, clickedOnLink: link, at: 0))
        }
        for text in ["https://pdf.example/x.pdf", "file:///Users/someone/secret", "ssh://host"] {
            gate.pdfViewWillClick(onLink: PDFView(), with: try #require(URL(string: text)))
        }
        #expect(
            links.opened.map(\.absoluteString) == [
                "https://example.com/a", "http://example.org", "mailto:me@example.com", "https://nsurl.example",
                "https://pdf.example/x.pdf"
            ]
        )
    }

    /// The text and PDF views of the rich modes have the link gate as their delegate.
    @MainActor
    @Test
    internal func theRichViewsAreGivenTheGateAsTheirDelegate() {
        let (_, text) = RichViews.textView(NSAttributedString(string: "link"))
        #expect(text.delegate is LinkGate)
        #expect(RichViews.pdfView(PDFDocument()).delegate is LinkGate)
    }

    // MARK: The pixel limit (V034)

    /// A PNG file of `width` by `height` pixels in one colour.
    private func png(_ width: Int, _ height: Int) throws -> Data {
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
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// An image with more pixels than the limit is not decoded, from memory or from the disk.
    @Test
    internal func anImageThatClaimsMorePixelsThanTheLimitIsNotDecoded() throws {
        let file = try png(64, 32)
        #expect(ImageDecoder.pixelLimit == 400_000_000)
        #expect(ImageDecoder().decode(file) != nil)
        #expect(ImageDecoder(pixelLimit: 64 * 32).decode(file) != nil)
        #expect(ImageDecoder(pixelLimit: 64 * 32 - 1).decode(file) == nil)
        // The same for a file on the disk.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("afm-bp2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("p.png")
        try file.write(to: url)
        #expect(ImageDecoder().decode(contentsOf: url) != nil)
        #expect(ImageDecoder(pixelLimit: 100).decode(contentsOf: url) == nil)
    }

    /// A link whose target size its file system gave is opened with that size, without being read.
    @Test
    internal func aLinkWhoseTargetSizeIsKnownIsNotReadToMeasureIt() throws {
        let url = try #require(URL(string: "link:///current.log"))
        let entry = FileItem(
            url: url,
            name: "current.log",
            kind: .symlink,
            stat: .init(size: 0),
            linkTargetSize: 123_456
        )
        let registry = FileSystemRegistry()
        registry.register(LinkProvider(entry))
        let source = try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag())
        #expect(source is ProviderByteSource && source.length == 123_456)
    }

    // MARK: Closing at the end

    /// When the program quits, the temporary copies are deleted in the background and the caller is
    /// told once, at once when there is nothing left.
    @Test
    internal func theTemporaryCopiesAreDeletedInTheBackgroundWhenTheProgramQuits() {
        let copies = TemporaryCopies()
        let memory = MemoryFileSystem()
        memory.addFile("/remote/clip.mov", String(repeating: "m", count: 5_000))
        let registry = FileSystemRegistry()
        registry.register(memory)
        let owner = ObjectIdentifier(copies)
        guard
            case .success(let local) = copies.localCopy(
                for: memory.url("/remote/clip.mov"),
                fileSystems: registry,
                owner: owner,
                cancellation: CancellationFlag()
            )
        else {
            Issue.record("no copy")
            return
        }
        #expect(FileManager.default.fileExists(atPath: local.path))
        let done = DispatchSemaphore(value: 0)
        copies.removeAll(waiting: false) { done.signal() }
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(!FileManager.default.fileExists(atPath: local.path))
        // Nothing left: the answer comes at once, and once.
        let again = DispatchSemaphore(value: 0)
        copies.removeAll(waiting: false) { again.signal() }
        #expect(again.wait(timeout: .now() + Wait.ceiling) == .success)
    }

    // MARK: A FIFO that takes the place of a file

    /// A new empty folder in the temporary directory; the caller removes it.
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("afm-bp2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A file swapped for a FIFO after it was opened gives no bytes, and its read returns.
    @Test
    internal func aFileSwappedForAFIFOAfterItWasOpenedDoesNotHoldUpTheRead() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("f.txt")
        try Data(repeating: UInt8(ascii: "z"), count: 1_000).write(to: url)
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let source = try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag())
        #expect(source.length == 1_000)
        #expect(try source.read(at: 0, count: 4) == Data("zzzz".utf8))
        // The reader that was kept belongs to the old file; a source closed meanwhile has none.
        source.close()
        ViewerCleanup.drain()
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        let done = DispatchSemaphore(value: 0)
        let outcome = Locked<Result<Data, any Error>?>(nil)
        let thread = Thread {
            outcome.withValue { $0 = Result { try source.read(at: 0, count: 10) } }
            done.signal()
        }
        thread.start()
        let finished = done.wait(timeout: .now() + Wait.ceiling) == .success
        if !finished {
            // Let the stuck open go, so the thread ends.
            let writer = open(url.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(finished, "the read of a FIFO did not return")
        if case .success(let data)? = outcome.withValue({ $0 }) { #expect(data.isEmpty, "a FIFO must not give bytes") }
    }

    /// A FIFO is refused when it is opened, and a direct read of one fails instead of blocking.
    @Test
    internal func aFIFOIsRefusedWhenOpeningAndWhenReadingDirectly() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pipe")
        #expect(mkfifo(url.path, 0o600) == 0)
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        #expect(throws: (any Error).self) {
            try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag())
        }
        let direct = ProviderByteSource(url: url, provider: LocalFileSystem(), length: 100)
        let done = DispatchSemaphore(value: 0)
        let threw = Locked(false)
        Thread {
            do { _ = try direct.read(at: 0, count: 10) } catch { threw.withValue { $0 = true } }
            done.signal()
        }
        .start()
        let finished = done.wait(timeout: .now() + Wait.ceiling) == .success
        if !finished {
            let writer = open(url.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(finished && threw.withValue { $0 })
    }
}
