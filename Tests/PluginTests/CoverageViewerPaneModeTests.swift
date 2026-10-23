import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The modes a Lister shows local files in, and the choices it makes when it opens one.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPaneModeTests {
    private static func png() throws -> Data {
        try CoverageViewerImages.encoded([CoverageViewerImages.picture(30, 20)], type: "public.png")
    }

    private static func pdf() throws -> Data {
        try CoverageViewerImages.encoded([CoverageViewerImages.picture(30, 20)], type: "com.adobe.pdf")
    }

    /// Images, animations, PDF, pages, RTF and sounds are shown by their views.
    @Test
    internal func localFilesAreShownByTheirViews() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let store = bench.setup.bench.kernel.settings
        store.set(false, forKey: "viewer.htmlAsText")
        bench.settings.playerVolume = 0
        let image = try #require(await bench.open(try bench.file("picture.png", Self.png())))
        #expect(await bench.wait { image.imageView != nil })
        #expect(image.statusText.hasPrefix("30 × 20") && image.percentText.hasSuffix("%"))
        let gif = try CoverageViewerImages.animation(count: 3, size: 20, delay: 0.1)
        let animation = try #require(await bench.open(try bench.file("anim.gif", gif)))
        #expect(await bench.wait { animation.imageView?.frameCount == 3 })
        let document = try #require(await bench.open(try bench.file("doc.pdf", Self.pdf())))
        #expect(await bench.wait { document.pdfView != nil })
        let page = try #require(
            await bench.open(try bench.file("page.html", text: "<p>Hello <a href=\"x.txt\">x</a></p>"))
        )
        page.setMode(.media)
        #expect(await bench.wait { page.webView != nil })
        page.followLink(try #require(URL(string: "https://example.com/a")))
        #expect(bench.links.opened == [URL(string: "https://example.com/a")])
        let rtf = "{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0 Rich {\\b text}.}"
        let rich = try #require(await bench.open(try bench.file("note.rtf", text: rtf)))
        #expect(await bench.wait { rich.richText?.string == "Rich text." })
        let sound = try #require(
            await bench.open(try bench.file("tone.wav", CoverageViewerMediaFiles.wav(seconds: 0.2)))
        )
        #expect(await bench.wait { sound.mediaView != nil })
        #expect(sound.statusText.contains("Image/Multimedia"))
    }

    /// Quick Look shows the files it is configured for; without it a file that is no image
    /// says what to do; a picture that cannot be decoded says so.
    @Test
    internal func previewsAndFilesThatCannotBeShown() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let slides = try #require(await bench.open(try bench.file("slides.key", text: "not really slides")))
        #expect(slides.mode == .preview)
        #expect(await bench.wait { slides.statusText.contains("Quick Look") })
        slides.setMode(.text)
        #expect(await bench.textShown(slides))
        bench.setup.bench.kernel.settings.set(false, forKey: "viewer.quickLook")
        slides.setMode(.media)
        #expect(await bench.wait { slides.statusText.contains("Image/Multimedia") && slides.mediaView == nil })
        var broken = try Self.png()
        broken.removeSubrange(20..<broken.count)
        let picture = try #require(await bench.open(try bench.file("broken.png", broken)))
        #expect(await bench.wait { picture.mode == .media && picture.imageView == nil && picture.pdfView == nil })
    }

    /// A text that is no file can only be shown as text.
    @Test
    internal func aTextIsShownAsTextOnly() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.setup.plugin.view(text: "plain words", title: "Words")
        let pane = try #require(bench.setup.plugin.windows.last?.pane)
        #expect(await bench.wait { pane.loaded != nil })
        pane.setMode(.media)
        #expect(await bench.wait { pane.statusText.contains("Image/Multimedia") })
        #expect(pane.imageView == nil && pane.mediaView == nil)
    }

    /// The font and the mode a file opens in come from the settings, or from what the file is.
    @Test
    internal func theStartupSettingsChooseFontAndMode() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let store = bench.setup.bench.kernel.settings
        let text = try bench.file("notes.txt", text: "Some text\nand more\n")
        for (font, slot) in [(1, FontSlot.ansi), (2, .ascii), (3, .variable)] {
            store.set(font, forKey: "viewer.startupFont")
            let pane = try #require(await bench.open(text))
            #expect(pane.fontSlot == slot)
        }
        store.set(0, forKey: "viewer.startupFont")
        let box =
            Data("Menu".utf8) + Data([0xC9, 0xCD, 0xCD, 0xBB, 0x0A, 0xBA, 0x20, 0xBA, 0x0A, 0xC8, 0xCD, 0xCD, 0xBC])
        let dos = try #require(await bench.open(try bench.file("dos.txt", box)))
        #expect(dos.fontSlot == .ascii && dos.mode == .text)
        store.set(2, forKey: "viewer.startupMode")
        #expect(try #require(await bench.open(text)).mode == .binary)
        store.set(3, forKey: "viewer.startupMode")
        #expect(try #require(await bench.open(text)).mode == .hex)
    }

    /// The encoding of each mode, and the font it is shown in.
    @Test
    internal func eachModeHasItsEncodingAndFont() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let fresh = ViewerPane(
            kernel: bench.setup.bench.kernel,
            settings: bench.settings,
            temporaryCopies: TemporaryCopies(),
            isEmbedded: false
        )
        #expect(fresh.encoding == .utf8)
        let pane = try #require(await bench.open(try bench.file("plain.txt", text: "abc\n")))
        pane.setMode(.unicode)
        #expect(pane.encoding == .utf16LE)
        pane.codePage = .utf16BE
        #expect(pane.encoding == .utf16BE)
        pane.codePage = .ansi
        #expect(pane.encoding == .utf16LE)
        let wide = Data([0xFF, 0xFE] + Array("wide".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let unicode = try #require(await bench.open(try bench.file("wide.txt", wide)))
        unicode.setMode(.unicode)
        #expect(unicode.encoding == .utf16LE)
        let store = bench.setup.bench.kernel.settings
        pane.fontSlot = .variable
        pane.setMode(.text)
        #expect(!pane.currentFont.isFixedPitch)
        store.set("Courier, 15", forKey: "viewer.variableFont")
        #expect(pane.currentFont.fontName.hasPrefix("Courier") && pane.currentFont.pointSize == 15)
        pane.setMode(.hex)
        #expect(pane.currentFont.isFixedPitch)
        pane.setMode(.binary)
        #expect(pane.currentFont.isFixedPitch)
    }

    /// HTML as text: the tags are removed with the encoding the page names; a page beyond the
    /// limit for that, or one that became shorter, is shown otherwise.
    @Test
    internal func htmlAsText() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let html =
            "<html><head><meta charset=\"utf-8\"></head><body><p>Grüße <a href=\"https://a.example\">a</a></p></body></html>"
        let pane = try #require(await bench.open(try bench.file("page.html", text: html)))
        #expect(pane.mode == .html)
        #expect(await bench.textShown(pane))
        #expect(pane.htmlLinks == ["https://a.example"])
        pane.redecodeHTML()
        pane.setFontSlot(.ascii)
        #expect(await bench.textShown(pane))
        // Without a charset the code page of the font decides.
        let plain = try #require(await bench.open(try bench.file("plain.html", text: "<p>caf\u{e9}</p>")))
        plain.codePage = .ansi
        plain.redecodeHTML()
        plain.present()
        #expect(await bench.textShown(plain))
        // A page larger than the limit for removing its tags is shown as plain text.
        var big = Data("<p>".utf8)
        big.append(Data(repeating: 0x61, count: Int(ViewerPane.htmlTextLimit)))
        let large = try #require(await bench.open(try bench.file("large.html", big)))
        #expect(await bench.wait { large.mode != .html })
    }
}
