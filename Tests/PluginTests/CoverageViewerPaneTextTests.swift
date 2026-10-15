import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// What the Lister does with text: finding, copying, going to a place, the context menu, the
/// status line and saving.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPaneTextTests {
    private static let text = (1...200).map { "Line \($0) of the text, with words\n" }.joined()

    /// Find: the dialog, its history, repeating in every direction, and what is said when nothing
    /// is found or the pattern is wrong.
    @Test
    internal func findingText() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        // Find next without an earlier search opens the dialog; cancelled, nothing happens.
        #expect(CoverageViewerMenus.run("Find next", in: "Edit", of: pane))
        #expect(bench.interaction.log.last == "form: Find" && pane.pager.selection == nil)
        bench.interaction.formAnswers = [.values(["text": .text("Line 12")])]
        #expect(CoverageViewerMenus.run("Find…", in: "Edit", of: pane))
        #expect(await bench.wait { pane.pager.selection != nil && pane.activity == nil })
        let first = try #require(pane.pager.selection)
        #expect(CoverageViewerMenus.run("Find next", in: "Edit", of: pane))
        #expect(await bench.wait { pane.activity == nil })
        #expect(CoverageViewerMenus.run("Find previous", in: "Edit", of: pane))
        #expect(await bench.wait { pane.activity == nil })
        #expect(CoverageViewerMenus.run("Find in the other direction", in: "Edit", of: pane))
        #expect(await bench.wait { pane.activity == nil && pane.pager.selection != nil })
        #expect(bench.settings.searchHistory == ["Line 12"])
        // A text from the history, picked in the dialog.
        bench.settings.searchHistory = ["words", "Line 12"]
        pane.lastSearch = nil
        bench.interaction.formAnswers = [.values(["text": .text(""), "history": .index(2)])]
        #expect(CoverageViewerMenus.run("Find…", in: "Edit", of: pane))
        #expect(await bench.wait { pane.activity == nil && pane.pager.selection?.count == first.count })
        #expect(bench.settings.searchHistory == ["Line 12", "words"])
        // Nothing typed: nothing is searched.
        bench.interaction.formAnswers = [.values(["text": .text(""), "history": .index(0)])]
        #expect(CoverageViewerMenus.run("Find…", in: "Edit", of: pane))
        // Not found, and a regular expression that is wrong.
        bench.interaction.formAnswers = [.values(["text": .text("no such words")])]
        #expect(CoverageViewerMenus.run("Find…", in: "Edit", of: pane))
        #expect(await bench.wait { bench.interaction.log.last?.contains("was not found") == true })
        bench.interaction.formAnswers = [.values(["text": .text("(unclosed"), "regex": .flag(true)])]
        #expect(CoverageViewerMenus.run("Find…", in: "Edit", of: pane))
        #expect(await bench.wait { bench.interaction.log.last == "inform: Find" })
    }

    /// Copying: as text and as hex, and not more than the clipboard takes.
    @Test
    internal func copyingTheSelection() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        pane.pager.reveal(offset: 0, select: 0..<4)
        #expect(await bench.wait { pane.pager.selection == 0..<4 })
        #expect(CoverageViewerMenus.run("Copy as text", in: "Edit", of: pane))
        #expect(await bench.wait { bench.scratch.pasteboard.string(forType: .string) == "Line" })
        #expect(CoverageViewerMenus.run("Copy as hex", in: "Edit", of: pane))
        #expect(await bench.wait { bench.scratch.pasteboard.string(forType: .string) == "4C 69 6E 65" })
        #expect(CoverageViewerMenus.run("Select all", in: "Edit", of: pane))
        #expect(pane.pager.selection == 0..<Int64(Self.text.utf8.count))
        let large = Data(repeating: 0x61, count: Int(ViewerPane.copyLimit / 2) + 10)
        let big = try #require(await bench.open(try bench.file("big.txt", large)))
        #expect(await bench.textShown(big))
        big.pager.selectAll()
        #expect(CoverageViewerMenus.run("Copy as hex", in: "Edit", of: big))
        #expect(bench.interaction.log.last?.contains("too large for the clipboard") == true)
    }

    /// Going to a percentage, an offset and a line; answers that are no numbers do nothing.
    @Test
    internal func goingToAPlace() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        bench.interaction.promptAnswers = [.text("50 %"), .text("abc")]
        #expect(CoverageViewerMenus.run("Go to position", in: "Edit", of: pane))
        #expect(await bench.wait { (pane.pager.position?.line ?? 0) > 10 })
        #expect(CoverageViewerMenus.run("Go to position", in: "Edit", of: pane))
        for (answer, offset) in [
            ("0x40", Int64(64)), ("$20", 32), ("1,000", 1_000), ("99999999", Int64(Self.text.utf8.count) - 1)
        ] {
            bench.interaction.promptAnswers = [.text(answer)]
            #expect(CoverageViewerMenus.run("Go to offset", in: "Edit", of: pane))
            #expect(await bench.wait { pane.pager.position?.offset == offset })
        }
        bench.interaction.promptAnswers = [.text("zz")]
        #expect(CoverageViewerMenus.run("Go to offset", in: "Edit", of: pane))
        bench.interaction.promptAnswers = [.text(" 20 ")]
        #expect(CoverageViewerMenus.run("Go to line", in: "Edit", of: pane))
        #expect(await bench.wait { pane.pager.position?.line == 20 })
        bench.interaction.promptAnswers = [.text("500")]
        #expect(CoverageViewerMenus.run("Go to line", in: "Edit", of: pane))
        #expect(await bench.wait { bench.interaction.log.last == "inform: There is no line 500." })
        bench.interaction.promptAnswers = [.text("x")]
        #expect(CoverageViewerMenus.run("Go to line", in: "Edit", of: pane))
        // On an image the same item sets the zoom; the percent item asks the same.
        let png = try CoverageViewerImages.encoded([CoverageViewerImages.picture(30, 20)], type: "public.png")
        let image = try #require(await bench.open(try bench.file("picture.png", png)))
        #expect(await bench.wait { image.imageView != nil })
        bench.interaction.promptAnswers = [.text("200")]
        #expect(CoverageViewerMenus.run("Go to position", in: "Edit", of: image) == false)
        image.goToPercent()
        #expect(image.imageView?.zoom == 2)
    }

    /// The context menu: copy and look up a selection, open a link under the mouse, copy the
    /// links of a page.
    @Test
    internal func theContextMenu() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let links = (1...200).map { _ in "https://example.com/page\n" }.joined()
        let pane = try #require(await bench.open(try bench.file("links.txt", text: links)))
        #expect(await bench.textShown(pane))
        let linkMenu = try #require(pane.makeContextMenu())
        #expect(linkMenu.items.map(\.title) == ["Copy URL", "Open in the default browser"])
        linkMenu.performActionForItem(at: 0)
        #expect(bench.scratch.pasteboard.string(forType: .string) == "https://example.com/page")
        linkMenu.performActionForItem(at: 1)
        #expect(bench.links.opened.last?.absoluteString == "https://example.com/page")
        pane.pager.reveal(offset: 0, select: 0..<24)
        #expect(await bench.wait { pane.pager.selection == 0..<24 })
        let menu = try #require(pane.makeContextMenu())
        #expect(
            menu.items.map(\.title).prefix(4) == [
                "Copy as text", "Copy as hex", "Search the web for the selection",
                "Open the selection as a link in the browser"
            ]
        )
        menu.performActionForItem(at: 2)
        #expect(await bench.wait { bench.links.opened.last?.host == "www.google.com" })
        menu.performActionForItem(at: 3)
        #expect(await bench.wait { bench.links.opened.last?.absoluteString == "https://example.com/page" })
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        #expect(await bench.wait { bench.scratch.pasteboard.string(forType: .string)?.hasPrefix("68 74") == true })
        // A selection longer than a search takes is not looked up.
        let count = bench.links.opened.count
        pane.pager.selectAll()
        try #require(pane.makeContextMenu()).performActionForItem(at: 2)
        await CoverageViewerPagerBench.settleAlone()
        #expect(bench.links.opened.count == count)
        // Plain words under the mouse give no menu; the links of a page are copied together.
        let words = try #require(
            await bench.open(try bench.file("words.txt", text: String(repeating: "word\n", count: 30)))
        )
        #expect(await bench.textShown(words))
        #expect(words.makeContextMenu() == nil)
        let page = "<p><a href=\"https://a.example\">a</a> <a href=\"https://b.example\">b</a></p>"
        let html = try #require(await bench.open(try bench.file("page.html", text: page)))
        #expect(await bench.textShown(html))
        html.pager.selectAll()
        let pageMenu = try #require(html.makeContextMenu())
        pageMenu.performActionForItem(at: pageMenu.items.count - 1)
        #expect(bench.scratch.pasteboard.string(forType: .string) == "https://a.example\nhttps://b.example")
    }

    /// The buttons of the strip: the files of the session, the percent and Cancel.
    @Test
    internal func theButtonsOfTheStrip() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let notes = try bench.file("notes.txt", text: Self.text)
        let other = try bench.file("other.txt", text: "Other\n")
        bench.setup.plugin.open(
            [ViewerItem(source: .file(notes), title: "notes"), ViewerItem(source: .file(other), title: "other")],
            internalOnly: false
        )
        let pane = try #require(bench.setup.plugin.windows.last?.pane)
        bench.prepare(pane)
        #expect(await bench.textShown(pane))
        func button(_ title: String) -> NSButton? {
            Self.buttons(of: pane).first { $0.title.hasPrefix(title) }
        }
        try #require(button(">>")).performClick(nil)
        #expect(await bench.wait { pane.item?.url == other })
        try #require(button("<<")).performClick(nil)
        #expect(await bench.wait { pane.item?.url == notes && pane.loaded != nil })
        #expect(await bench.textShown(pane))
        try #require(Self.buttons(of: pane).first { $0.toolTip == "Go to position (in %)" }).performClick(nil)
        #expect(bench.interaction.log.last?.hasPrefix("prompt: Go to position") == true)
        let flag = CancellationFlag()
        pane.activity = ("Working", 0.5, flag)
        #expect(pane.statusText == "Working")
        try #require(button("Cancel")).performClick(nil)
        #expect(flag.isCancelled)
        pane.activity = nil
    }

    /// Save as: what the work does when it fails, and when it was stopped.
    @Test
    internal func theWorkOfSaveAs() throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let locked = bench.folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        #expect(chmod(locked.path, 0o500) == 0)
        defer { chmod(locked.path, 0o700) }
        let source = DataByteSource(Data("text".utf8))
        let monitor = CoverageViewerJobMonitor()
        #expect(ViewerPane.save(source, to: locked.appendingPathComponent("x"), monitor: monitor) != nil)
        monitor.cancellation.cancel()
        #expect(ViewerPane.save(source, to: locked.appendingPathComponent("x"), monitor: monitor) == nil)
        let fresh = CoverageViewerJobMonitor()
        #expect(ViewerPane.save(source, to: bench.folder.appendingPathComponent("y"), monitor: fresh) == nil)
        #expect(fresh.reports > 0)
    }

    private static func buttons(of view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(of: subview)
        }
    }
}
