import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import TestSupport
import Testing

@testable import ViewerPlugin

/// Stands in for the part of a panel the quick view covers.
private final class FakeOverlayHost: PanelOverlayHost {
    var overlay: NSView?
}

/// The viewer driven through its commands, its service and its keys: Lister windows that are
/// never put on screen, and the quick view over a fake panel. Files live in a memory file
/// system, so everything is read through the provider interface.
@MainActor @Suite(.serialized) struct ViewerWindows {
    let memory = MemoryFileSystem()
    let bench: TestBench
    let plugin: ViewerPlugin
    fileprivate let hosts: [ObjectIdentifier: FakeOverlayHost]
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }

    var commands: CommandRegistry { bench.commands }
    var ui: ScriptedInteraction { bench.ui }

    init() throws {
        _ = NSApplication.shared
        var lines: [String] = []
        for number in 1...5_000 {
            lines.append("Line \(number) of the long text, needle\(number % 1_000 == 0 ? " GOLD" : "")")
        }
        memory.addFile("/A/long.txt", lines.joined(separator: "\n"))
        memory.addFile("/A/short.txt", "Grüße\tfrom a file\nsecond line")
        memory.addFile(
            "/A/page.html",
            "<html><body><h1>Title</h1><p>See <a href=\"https://example.com\">this</a>.</p></body></html>")
        memory.addFile("/A/docs/inner.txt", "inside")
        memory.addFile("/A/docs/more/deep.txt", "12345")
        memory.addFile("/B/other.txt", "other")
        try Self.write(
            Data([0x4D, 0x5A, 0x00, 0x01, 0x02, 0x03] + Array(repeating: UInt8(0xFF), count: 300)), to: "/A/tool.bin",
            in: memory)
        try Self.write(
            Data([0xFF, 0xFE] + (ViewerEncoding.utf16LE.encode("Wide text\r\nzwei") ?? [])), to: "/A/wide.txt",
            in: memory)
        try Self.write(
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]), to: "/A/broken.png", in: memory)
        var hosts: [ObjectIdentifier: FakeOverlayHost] = [:]
        let lookup = HostLookup()
        plugin = ViewerPlugin(
            overlayHost: { lookup.hosts[ObjectIdentifier($0)] }, quickViewDelay: 0.01, showsWindows: false)
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
        hosts[ObjectIdentifier(bench.left)] = FakeOverlayHost()
        hosts[ObjectIdentifier(bench.right)] = FakeOverlayHost()
        lookup.hosts = hosts
        self.hosts = hosts
    }

    private final class HostLookup {
        var hosts: [ObjectIdentifier: FakeOverlayHost] = [:]
    }

    static func write(_ data: Data, to path: String, in memory: MemoryFileSystem) throws {
        let writer = try memory.write(memory.url(path))
        try writer.write(data)
        try writer.close(attributes: FileAttributes())
    }

    fileprivate func host(_ panel: FakePanel) -> FakeOverlayHost { hosts[ObjectIdentifier(panel)]! }

    @discardableResult
    func wait(upTo seconds: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        return condition()
    }

    /// A key press as the window would deliver it.
    func key(_ characters: String, code: UInt16 = 0, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func functionKey(_ number: Int, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        return key("", code: codes[number - 1], flags)
    }

    /// Opens a Lister on a file of the left panel and waits until its text is shown.
    func openLister(on name: String) async throws -> ViewerWindowController {
        bench.left.moveCursor(toName: name)
        #expect(commands.perform(.viewSingle))
        let controller = try #require(plugin.windows.last)
        controller.pane.pasteboard = pasteboard
        controller.window?.layoutIfNeeded()
        #expect(await wait { controller.pane.loaded != nil })
        return controller
    }

    /// Waits until the pager shows the rows of the pane's current mode.
    func rowsShown(_ controller: ViewerWindowController) async -> Bool {
        let pane = controller.pane
        return await wait {
            pane.pager.document?.layout == pane.layout
                && pane.pager.document?.encoding == pane.encoding.forLayout(pane.layout)
                && !pane.pager.isIndexing && pane.pager.position != nil
        }
    }

    func visibleText(_ pane: ViewerPane, rows: Int = 3) -> [String] {
        ((try? pane.pager.document?.rows(from: 0, count: rows)) ?? []).map(\.text)
    }

    // MARK: Registration

    @Test func theViewerRegistersItsCommandsKeysPageAndService() {
        let keys = bench.kernel.keyBindings
        #expect(keys.command(for: .f(3)) == .view && keys.command(for: .f(3, .shift)) == .viewSingle)
        #expect(keys.command(for: .f(3, [.option, .shift])) == .viewInternalSingle)
        #expect(keys.command(for: Shortcut(.character("q"), .control)) == .quickView)
        #expect(keys.command(for: Shortcut(.character("q"), [.control, .shift])) == .separateQuickView)
        #expect(keys.conflicts.isEmpty)
        for id in [
            CommandID.view, .viewSingle, .viewMarked, .viewInternalSingle, .viewInternalMarked, .quickView,
            .quickViewInternalOnly, .hideQuickView,
            .updateQuickView, .separateQuickView, .separateQuickViewInternalOnly, .configureLister
        ] {
            #expect(commands[id] != nil, "\(id)")
        }
        #expect(bench.kernel.menus.menus.map(\.title) == ["Files", "Show"])
        #expect(
            bench.kernel.menus.menus[0].items == [.view]
                && bench.kernel.menus.menus[1].items == [.quickView, .separateQuickView])
        #expect(bench.kernel.menus.contextMenu(onItem: true) == [.view])
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.view, .quickView])
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Lister"])
        #expect(bench.kernel.services.find((any ViewerService).self) != nil)
        #expect(commands[.view]?.barLabel == "View" && commands[.view]?.runsDuringJobs == true)
    }

    @Test func viewingNeedsAFile() {
        bench.left.model.moveCursor(to: 0)
        #expect(bench.left.model.cursorIsOnParentRow && !commands.isEnabled(.view) && !commands.isEnabled(.viewSingle))
        bench.left.moveCursor(toName: "docs")
        #expect(!commands.isEnabled(.view) && !commands.isEnabled(.viewInternalSingle))
        bench.left.moveCursor(toName: "short.txt")
        #expect(commands.isEnabled(.view) && commands.isEnabled(.viewSingle) && commands.isEnabled(.viewMarked))
        #expect(!commands.isEnabled(.hideQuickView) && !commands.isEnabled(.updateQuickView))
    }

    // MARK: Lister windows

    @Test func theServiceShowsFilesOfAnyFileSystemAndTexts() async throws {
        let service = try #require(bench.kernel.services.find((any ViewerService).self))
        service.view(memory.url("/A/short.txt"))
        let file = try #require(plugin.windows.last)
        #expect(
            file.window?.title == "Lister - [mem:///A/short.txt]"
                || file.window?.title.hasSuffix("/A/short.txt]") == true)
        file.window?.layoutIfNeeded()
        #expect(await rowsShown(file))
        #expect(file.pane.mode == .utf8 && visibleText(file.pane) == ["Grüße   from a file", "second line"])
        #expect(
            file.pane.statusText.contains("UTF-8") && file.pane.statusText.contains("Line 1")
                && file.pane.statusText.hasSuffix("31 bytes"))
        #expect(file.pane.percentText == "100 %")

        service.view(text: "a log\nof three\nlines", title: "Result list")
        let text = try #require(plugin.windows.last)
        text.window?.layoutIfNeeded()
        #expect(plugin.windows.count == 2 && text.window?.title == "Lister - [Result list]")
        #expect(await rowsShown(text))
        #expect(visibleText(text.pane) == ["a log", "of three", "lines"])
        // A text is no file: the modes that need one are not offered, and nothing can be edited.
        #expect(
            text.pane.menuEntries("Options").compactMap { $0 }.first { $0.title.hasPrefix("4 ") }?.isEnabled == false)
        text.close()
        #expect(plugin.windows.count == 1)
        plugin.stop()
        #expect(plugin.windows.isEmpty)
    }

    @Test func aTextIsLaidOutOnceWhenItsWindowKeepsItsSize() async throws {
        let controller = try await openLister(on: "long.txt")
        #expect(await rowsShown(controller))
        let document = try #require(controller.pane.pager.document)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(controller.pane.pager.document === document)
        // A narrower window wraps the text anew, a moment after the change.
        let columns = controller.pane.pager.columnsThatFit
        controller.window?.setContentSize(NSSize(width: 500, height: 400))
        controller.window?.layoutIfNeeded()
        #expect(
            await wait {
                controller.pane.pager.document !== document
                    && controller.pane.pager.document?.layout == controller.pane.layout
            })
        #expect(controller.pane.pager.columnsThatFit < columns)
    }

    @Test func aMissingFileIsReportedInTheWindow() async throws {
        plugin.view(memory.url("/A/nothing.txt"))
        let controller = try #require(plugin.windows.last)
        #expect(await wait { controller.pane.failure != nil })
        #expect(
            controller.pane.loaded == nil && controller.pane.statusText == controller.pane.failure
                && controller.pane.pager.document == nil)
    }

    @Test func severalMarkedFilesAreSteppedThroughWithNAndP() async throws {
        bench.left.model.select(mask: "*.txt")
        #expect(commands.perform(.view))
        let controller = try #require(plugin.windows.last)
        controller.window?.layoutIfNeeded()
        #expect(
            controller.items.map(\.title).map { $0.components(separatedBy: "/").last } == [
                "long.txt", "short.txt", "wide.txt"
            ])
        #expect(controller.pane.fileCounter == (0, 3))
        #expect(await wait { controller.pane.loaded?.item.url?.lastPathComponent == "long.txt" })
        #expect(controller.pane.handleKey(key("n")))
        #expect(controller.index == 1 && controller.window?.title.hasSuffix("short.txt]") == true)
        #expect(await wait { controller.pane.loaded?.item.url?.lastPathComponent == "short.txt" })
        #expect(controller.pane.handleKey(key("", code: 124, .option)))
        #expect(controller.index == 2)
        // At the end N does nothing; P goes back.
        controller.pane.handleKey(key("n"))
        #expect(controller.index == 2)
        controller.pane.handleKey(key("p"))
        #expect(controller.index == 1)
        // With a location the command shows that file alone, whatever is marked.
        commands.perform(.view, .location(memory.url("/B/other.txt")))
        #expect(plugin.windows.last?.items.count == 1 && plugin.windows.last?.pane.fileCounter.count == 1)
        #expect(plugin.windows.last?.pane.handleKey(key("n")) == false)
        // Without anything marked, F3 shows the file under the cursor.
        bench.left.model.clearSelection()
        bench.left.moveCursor(toName: "page.html")
        commands.perform(.view)
        #expect(plugin.windows.last?.items.map { $0.url?.lastPathComponent } == ["page.html"])
    }

    @Test func modesAreChosenAtStartupAndSwitchedWithTheirKeys() async throws {
        let controller = try await openLister(on: "short.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        #expect(pane.mode == .utf8 && pane.encoding == .utf8)
        pane.handleKey(key("3"))
        #expect(pane.mode == .hex && pane.pager.document?.layout == .hex)
        #expect(
            visibleText(pane, rows: 1) == [
                "00000000: 47 72 C3 BC C3 9F 65 09|66 72 6F 6D 20 61 20 66 | GrÃ¼ÃŸe.from a f"
            ])
        pane.handleKey(key("2"))
        #expect(pane.mode == .binary && pane.pager.document?.layout == .binary(width: 75))
        pane.handleKey(key("1"))
        #expect(pane.mode == .text && pane.encoding == .ansi)
        #expect(await rowsShown(controller))
        // Seven characters now, so the tab is one column wide.
        #expect(visibleText(pane, rows: 1) == [ViewerEncoding.ansi.string(from: Data("Grüße".utf8)) + " from a file"])
        // S shows the same bytes in the DOS character set; the Encoding menu overrides the font.
        pane.handleKey(key("s"))
        #expect(pane.fontSlot == .ascii && pane.encoding == .dos)
        pane.setEncoding(ViewerEncoding.codePage(1_251))
        #expect(pane.mode == .text && pane.encoding.codePage == 1_251)
        pane.setEncoding(.utf16BE)
        #expect(pane.mode == .unicode && pane.encoding == .utf16BE)
        pane.handleKey(key("7"))
        #expect(pane.mode == .utf8 && pane.encoding == .utf8)
        // W turns wrapping off and on; the option is remembered.
        #expect(pane.settings.wrap)
        pane.handleKey(key("w"))
        #expect(
            !pane.settings.wrap && pane.pager.document == nil
                || pane.layout == .text(TextLayoutOptions(columns: 1_024, wordWrap: false)))
        pane.handleKey(key("w"))
        #expect(pane.settings.wrap && ListerSettings(bench.kernel.settings).wrap)
        pane.handleKey(functionKey(6))
        #expect(!pane.settings.caret && !pane.pager.showsCaret)
        // Q closes the window.
        #expect(pane.handleKey(key("q")) && plugin.windows.isEmpty)
    }

    @Test func binaryUnicodeHtmlAndImagesOpenInTheirModes() async throws {
        let binary = try await openLister(on: "tool.bin")
        #expect(binary.pane.mode == .binary && binary.pane.statusText.contains("Binary"))
        let wide = try await openLister(on: "wide.txt")
        #expect(wide.pane.mode == .unicode && wide.pane.encoding == .utf16LE)
        #expect(await rowsShown(wide))
        #expect(visibleText(wide.pane) == ["Wide text", "zwei"])
        let html = try await openLister(on: "page.html")
        #expect(html.pane.mode == .html)
        #expect(await wait { !html.pane.htmlLinks.isEmpty })
        #expect(await rowsShown(html))
        #expect(
            visibleText(html.pane) == ["Title", "See this {https://example.com}."]
                && html.pane.htmlLinks == ["https://example.com"])
        // 1 shows the source.
        html.pane.handleKey(key("1"))
        #expect(html.pane.mode == .text && html.pane.htmlLinks.isEmpty)
        let image = try await openLister(on: "broken.png")
        #expect(image.pane.mode == .media)
        #expect(await wait { image.pane.statusText.hasPrefix("Image/Multimedia") })
        // Without plugins and multimedia the same file is shown as what it is: bytes.
        bench.left.moveCursor(toName: "broken.png")
        commands.perform(.viewInternalSingle)
        let plain = try #require(plugin.windows.last)
        #expect(await wait { plain.pane.loaded != nil })
        #expect(plain.pane.internalOnly && plain.pane.mode == .binary)
        #expect(
            plain.pane.menuEntries("Options").compactMap { $0 }.first { $0.title.hasPrefix("8 ") }?.isEnabled == false)
    }

    @Test func theConfigurationDecidesTheStartupMode() async throws {
        ui.formAnswers = [
            .values([
                "viewer.startupMode": .index(3), "viewer.htmlAsText": .flag(false), "viewer.binaryWidth": .text("40")
            ])
        ]
        #expect(commands.perform(.configureLister))
        #expect(ui.forms.last?.count == bench.kernel.preferences.pages[0].preferences.count)
        let hex = try await openLister(on: "short.txt")
        #expect(hex.pane.mode == .hex)
        let html = try await openLister(on: "page.html")
        #expect(html.pane.mode == .hex)
        html.pane.handleKey(key("2"))
        #expect(html.pane.layout == .binary(width: 40))
        // Changing the configuration reaches the windows that are open.
        ui.formAnswers = [.values(["viewer.binaryWidth": .text("16")])]
        html.pane.onConfigure()
        #expect(html.pane.layout == .binary(width: 16))
        #expect(await wait { html.pane.pager.document?.layout == .binary(width: 16) })
        ui.formAnswers = [.cancel]
        commands.perform(.configureLister)
        #expect(ListerSettings(bench.kernel.settings).binaryWidth == 16)
    }

    // MARK: Search, selection, clipboard

    @Test func findSearchesTheWholeFileAndRepeatsInBothDirections() async throws {
        let controller = try await openLister(on: "long.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        let source = try #require(memory.contents("/A/long.txt"))
        func offset(of text: String, last: Bool = false) -> Int64 {
            let range = source.range(of: text, options: last ? .backwards : [])!
            return Int64(source.utf8.distance(from: source.startIndex, to: range.lowerBound))
        }
        ui.formAnswers = [.values(["text": .text("gold"), "case": .flag(false)])]
        #expect(pane.handleKey(functionKey(7)))
        #expect(await wait { pane.pager.selection != nil && pane.activity == nil })
        #expect(pane.pager.selection == offset(of: "GOLD")..<offset(of: "GOLD") + 4)
        #expect(await wait { pane.statusText.contains("Line 1,000") && pane.statusText.contains("4 bytes selected") })
        // F3 finds the next one, Shift+F3 the one before, Ctrl+F3 turns around.
        pane.handleKey(functionKey(3))
        #expect(
            await wait {
                pane.pager.selection?.lowerBound == offset(of: "Line 2000 ")
                    + Int64("Line 2000 of the long text, needle ".utf8.count)
            })
        pane.handleKey(functionKey(3, .shift))
        #expect(await wait { pane.pager.selection?.lowerBound == offset(of: "GOLD") })
        pane.handleKey(functionKey(5, .control))
        #expect(await wait { pane.pager.selection?.lowerBound != offset(of: "GOLD") && pane.activity == nil })
        #expect(await wait { pane.statusText.contains("Line 2,000") })
        // Backwards from the end, as a regular expression.
        pane.pager.perform(.fileEnd)
        #expect(await wait { pane.pager.selection == nil && pane.statusText.contains("Line 5,000") })
        ui.formAnswers = [
            .values([
                "text": .text("needle G.LD$"), "regex": .flag(true), "backwards": .flag(true), "case": .flag(true)
            ])
        ]
        pane.find()
        #expect(await wait { pane.pager.selection?.lowerBound == offset(of: "needle GOLD", last: true) })
        #expect(await wait { pane.statusText.contains("Line 5,000") })
        #expect(pane.settings.searchHistory == ["needle G.LD$", "gold"] && pane.settings.searchOptions.regex)
        // What is not there is said so, and a bad pattern too.
        ui.formAnswers = [.values(["text": .text("no such text"), "regex": .flag(false), "backwards": .flag(false)])]
        pane.find()
        #expect(await wait { ui.log.contains("inform: \"no such text\" was not found.") })
        ui.formAnswers = [.values(["text": .text("zz"), "hex": .flag(true)])]
        pane.find()
        #expect(ui.log.contains("inform: Find"))
    }

    @Test func theSelectionIsCopiedAsTextOrAsHex() async throws {
        let controller = try await openLister(on: "short.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        #expect(pane.menuEntries("Edit").compactMap { $0 }.first { $0.title == "Copy as text" }?.isEnabled == false)
        #expect(pane.handleKey(key("a", .control)))
        #expect(pane.pager.selection == 0..<31)
        #expect(pane.handleKey(key("c", .control)))
        #expect(await wait { pasteboard.string(forType: .string) == "Grüße\tfrom a file\nsecond line" })
        // The text cursor: Shift with the cursor keys selects.
        pane.pager.perform(.fileStart)
        pane.pager.perform(.right, extending: true)
        pane.pager.perform(.right, extending: true)
        pane.pager.perform(.right, extending: true)
        #expect(pane.pager.selection == 0..<4)
        #expect(pane.handleKey(key("c", [.control, .shift])))
        #expect(await wait { pasteboard.string(forType: .string) == "47 72 C3 BC" })
        pane.pager.perform(.down)
        #expect(await wait { pane.pager.selection == nil && pane.statusText.contains("Line 2") })
        pane.pager.perform(.rowEnd, extending: true)
        pane.copySelection(asHex: false)
        #expect(await wait { pasteboard.string(forType: .string) == "ond line" })
        pane.pager.perform(.wordLeft, extending: false)
        pane.pager.perform(.rowStart, extending: true)
        #expect(pane.pager.selection == 20..<27)
    }

    @Test func positionsAreReachedByPercentOffsetAndLine() async throws {
        let controller = try await openLister(on: "long.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        ui.promptAnswers = [.text("4000")]
        pane.goToLine()
        #expect(await wait { pane.statusText.contains("Line 4,000") })
        ui.promptAnswers = [.text("0x0")]
        pane.goToOffset()
        #expect(await wait { pane.statusText.contains("Line 1 ") })
        ui.promptAnswers = [.text("50,5")]
        pane.goToPercent()
        #expect(await wait { pane.pager.position.map { (2_400...2_700).contains($0.line) } == true })
        #expect(await wait { pane.percentText == "51 %" || pane.percentText == "50 %" || pane.percentText == "52 %" })
        ui.promptAnswers = [.text("99999")]
        pane.goToLine()
        #expect(await wait { ui.log.contains("inform: There is no line 99999.") })
        #expect(
            ViewerPane.number(in: "20,7 %") == 20.7 && ViewerPane.offset(in: "$FF") == 255
                && ViewerPane.offset(in: "1,024") == 1_024)
        // The view draws what it holds.
        let image = try #require(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: image)
        #expect(image.pixelsWide > 0)
        #expect(
            ViewerPane.printableText(of: try #require(pane.pager.document), in: 0..<60).text
                == "Line 1 of the long text, needle\nLine 2 of the long text, needle\n")
    }

    // MARK: Quick view

    @Test func theQuickViewCoversTheTargetPanelAndFollowsTheCursor() async throws {
        bench.left.moveCursor(toName: "short.txt")
        #expect(commands.perform(.quickView))
        let quick = try #require(plugin.quickView)
        #expect(host(bench.right).overlay != nil && host(bench.left).overlay == nil && commands.isChecked(.quickView))
        #expect(await wait { quick.pane.loaded?.item.url?.lastPathComponent == "short.txt" })
        #expect(quick.headerText == "short.txt" && quick.pane.isEmbedded)
        // The cursor moves on: the pane follows, and only the last of several quick moves is loaded.
        for name in ["long.txt", "page.html", "wide.txt"] {
            bench.left.moveCursor(toName: name)
            bench.kernel.panelEvents.post(.cursorMoved, from: bench.left)
        }
        #expect(await wait { quick.pane.loaded?.item.url?.lastPathComponent == "wide.txt" })
        #expect(quick.headerText == "wide.txt" && quick.pane.mode == .unicode)
        // Events of the covered panel's cursor mean nothing to it.
        bench.kernel.panelEvents.post(.cursorMoved, from: bench.right)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(quick.shownItem?.name == "wide.txt")
        // On a folder it tells what the folder holds; on `[..]` it shows nothing.
        bench.left.moveCursor(toName: "docs")
        bench.kernel.panelEvents.post(.cursorMoved, from: bench.left)
        #expect(await wait { quick.pane.folderSummary != nil })
        #expect(
            quick.pane.folderSummary == FolderSummary(files: 2, folders: 1, bytes: 11) && quick.headerText == "docs"
                && quick.pane.item == nil)
        bench.left.show(memory.url("/A/docs"))
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        #expect(await wait { quick.shownItem == nil && quick.headerText.isEmpty && quick.pane.folderSummary == nil })
        bench.left.moveCursor(toName: "inner.txt")
        bench.kernel.panelEvents.post(.cursorMoved, from: bench.left)
        #expect(await wait { quick.pane.loaded?.item.url?.lastPathComponent == "inner.txt" })
        #expect(commands.isEnabled(.updateQuickView) && commands.perform(.updateQuickView))
        // Ctrl+Q again brings the file list back.
        #expect(commands.perform(.quickView))
        #expect(plugin.quickView == nil && host(bench.right).overlay == nil && !commands.isChecked(.quickView))
    }

    @Test func switchingToTheCoveredPanelOrChangingItsPlaceEndsTheQuickView() async {
        bench.left.moveCursor(toName: "short.txt")
        commands.perform(.quickView)
        #expect(plugin.quickView != nil)
        bench.kernel.panelEvents.post(.becameSource, from: bench.right)
        #expect(plugin.quickView == nil && host(bench.right).overlay == nil)

        commands.perform(.quickViewInternalOnly)
        #expect(plugin.quickView?.pane.internalOnly == true && host(bench.right).overlay != nil)
        bench.kernel.panelEvents.post(.locationChanged, from: bench.right)
        #expect(plugin.quickView == nil && host(bench.right).overlay == nil)

        // From the other side it covers the other panel.
        bench.right.moveCursor(toName: "other.txt")
        bench.right.focus()
        commands.perform(.quickView)
        #expect(host(bench.left).overlay != nil && host(bench.right).overlay == nil)
        #expect(await wait { plugin.quickView?.pane.loaded?.item.url?.lastPathComponent == "other.txt" })
        #expect(commands.perform(.hideQuickView))
        #expect(plugin.quickView == nil && host(bench.left).overlay == nil)
        plugin.stop()
    }

    @Test func theSeparateQuickViewIsAWindowThatFollowsTheCursor() async throws {
        bench.left.moveCursor(toName: "short.txt")
        #expect(commands.perform(.separateQuickView))
        let controller = try #require(plugin.windows.last)
        #expect(controller.followsCursor && commands.isChecked(.separateQuickView))
        #expect(await wait { controller.pane.loaded?.item.url?.lastPathComponent == "short.txt" })
        #expect(controller.window?.title.hasPrefix("Lister* - [") == true)
        bench.left.moveCursor(toName: "long.txt")
        bench.kernel.panelEvents.post(.cursorMoved, from: bench.left)
        #expect(await wait { controller.pane.loaded?.item.url?.lastPathComponent == "long.txt" })
        // It follows whichever panel is the source.
        bench.right.moveCursor(toName: "other.txt")
        bench.right.focus()
        bench.kernel.panelEvents.post(.becameSource, from: bench.right)
        #expect(await wait { controller.pane.loaded?.item.url?.lastPathComponent == "other.txt" })
        #expect(commands.perform(.separateQuickView))
        #expect(plugin.windows.isEmpty && !commands.isChecked(.separateQuickView))
    }
}
