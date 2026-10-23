import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import ViewerPlugin

/// The viewer's commands, keys and service, and its Lister windows, never put on screen.
///
/// Files live in a memory file system, so everything is read through the provider interface.
@MainActor
@Suite(.serialized)
internal struct ViewerPluginTests: ViewerPluginFixture {
    /// The viewer and the program around it, made for this test.
    internal let setup: ViewerPluginSetup

    /// Makes the viewer over its files for this test.
    internal init() throws {
        setup = try ViewerPluginSetup()
    }

    // MARK: Registration

    /// The viewer registers its commands, keys, menus, toolbar buttons, preference page and service.
    @Test
    internal func theViewerRegistersItsCommandsKeysPageAndService() {
        let keys = bench.kernel.keyBindings
        #expect(keys.command(for: .f(3)) == .view && keys.command(for: .f(3, .shift)) == .viewSingle)
        #expect(keys.command(for: .f(3, [.option, .shift])) == .viewInternalSingle)
        #expect(keys.command(for: Shortcut(.character("q"), .control)) == .quickView)
        #expect(keys.command(for: Shortcut(.character("q"), [.control, .shift])) == .separateQuickView)
        #expect(bench.kernel.keyClashes.isEmpty)
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
                && bench.kernel.menus.menus[1].items == [.quickView, .separateQuickView]
        )
        #expect(bench.kernel.menus.contextMenu(onItem: true) == [.view])
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.view, .quickView])
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Lister"])
        #expect(bench.kernel.services.find((any ViewerService).self) != nil)
        #expect(commands[.view]?.barLabel == "View" && commands[.view]?.runsDuringJobs == true)
    }

    /// Viewing is offered only on a file, not on `[..]` or a folder.
    @Test
    internal func viewingNeedsAFile() {
        bench.left.model.moveCursor(to: 0)
        #expect(bench.left.model.cursorIsOnParentRow && !commands.isEnabled(.view) && !commands.isEnabled(.viewSingle))
        bench.left.moveCursor(toName: "docs")
        #expect(!commands.isEnabled(.view) && !commands.isEnabled(.viewInternalSingle))
        bench.left.moveCursor(toName: "short.txt")
        #expect(commands.isEnabled(.view) && commands.isEnabled(.viewSingle) && commands.isEnabled(.viewMarked))
        #expect(!commands.isEnabled(.hideQuickView) && !commands.isEnabled(.updateQuickView))
    }

    // MARK: Lister windows

    /// The service shows a file of any file system and a text of its own, each in a window, closed with the viewer.
    @Test
    internal func theServiceShowsFilesOfAnyFileSystemAndTexts() async throws {
        let service = try #require(bench.kernel.services.find((any ViewerService).self))
        service.view(memory.url("/A/short.txt"))
        let file = try #require(plugin.windows.last)
        #expect(
            file.window?.title == "Lister - [mem:///A/short.txt]"
                || file.window?.title.hasSuffix("/A/short.txt]") == true
        )
        file.window?.layoutIfNeeded()
        #expect(await rowsShown(file))
        #expect(file.pane.mode == .utf8 && visibleText(file.pane, rows: 3) == ["Grüße   from a file", "second line"])
        #expect(
            file.pane.statusText.contains("UTF-8") && file.pane.statusText.contains("Line 1")
                && file.pane.statusText.hasSuffix("31 bytes")
        )
        #expect(file.pane.percentText == "100 %")

        service.view(text: "a log\nof three\nlines", title: "Result list")
        let text = try #require(plugin.windows.last)
        text.window?.layoutIfNeeded()
        #expect(plugin.windows.count == 2 && text.window?.title == "Lister - [Result list]")
        #expect(await rowsShown(text))
        #expect(visibleText(text.pane, rows: 3) == ["a log", "of three", "lines"])
        // A text is no file: the modes that need one are not offered, and nothing can be edited.
        #expect(
            text.pane.menuEntries("Options").compactMap(\.self).first { $0.title.hasPrefix("4 ") }?.isEnabled == false
        )
        text.close()
        #expect(plugin.windows.count == 1)
        plugin.stop()
        #expect(plugin.windows.isEmpty)
    }

    /// A text is laid out again only when its window's width changes, not when the size stays.
    @Test
    internal func aTextIsLaidOutOnceWhenItsWindowKeepsItsSize() async throws {
        let controller = try await openLister(on: "long.txt")
        // The window's layout is finished first: on a busy machine the text may be shown before
        // a layout pass the window still owes, which then wraps it once more for the final width.
        controller.window?.layoutIfNeeded()
        #expect(await rowsShown(controller))
        let document = try #require(controller.pane.pager.document)
        // The same size again changes nothing, and neither does the end of a resize (what the
        // pane does once a size has stopped changing).
        if let size = controller.window?.contentView?.frame.size { controller.window?.setContentSize(size) }
        controller.pane.layOutAfterResize(whileResizing: false)
        #expect(controller.pane.pager.document === document)
        // A narrower window wraps the text anew, a moment after the change.
        let columns = controller.pane.pager.columnsThatFit
        controller.window?.setContentSize(NSSize(width: 500, height: 400))
        controller.window?.layoutIfNeeded()
        #expect(
            await wait {
                controller.pane.pager.document !== document
                    && controller.pane.pager.document?.layout == controller.pane.layout
            }
        )
        #expect(controller.pane.pager.columnsThatFit < columns)
    }

    /// A missing file is reported in the window, and nothing is shown.
    @Test
    internal func aMissingFileIsReportedInTheWindow() async throws {
        plugin.view(memory.url("/A/nothing.txt"))
        let controller = try #require(plugin.windows.last)
        #expect(await wait { controller.pane.failure != nil })
        #expect(
            controller.pane.loaded == nil && controller.pane.statusText == controller.pane.failure
                && controller.pane.pager.document == nil
        )
    }

    /// The marked files are stepped through with N and P; a location or no mark shows one file.
    @Test
    internal func severalMarkedFilesAreSteppedThroughWithNAndP() async throws {
        bench.left.model.select(mask: "*.txt")
        #expect(commands.perform(.view))
        let controller = try #require(plugin.windows.last)
        controller.window?.layoutIfNeeded()
        #expect(
            controller.items.map(\.title).map { $0.components(separatedBy: "/").last } == [
                "long.txt", "short.txt", "wide.txt"
            ]
        )
        #expect(controller.pane.fileCounter == (0, 3))
        #expect(await wait { controller.pane.loaded?.item.url?.lastPathComponent == "long.txt" })
        #expect(controller.pane.handleKey(try key("n", [])))
        #expect(controller.index == 1 && controller.window?.title.hasSuffix("short.txt]") == true)
        #expect(await wait { controller.pane.loaded?.item.url?.lastPathComponent == "short.txt" })
        #expect(controller.pane.handleKey(try key(code: 124, .option)))
        #expect(controller.index == 2)
        // At the end N does nothing; P goes back.
        controller.pane.handleKey(try key("n", []))
        #expect(controller.index == 2)
        controller.pane.handleKey(try key("p", []))
        #expect(controller.index == 1)
        // With a location the command shows that file alone, whatever is marked.
        commands.perform(.view, .location(memory.url("/B/other.txt")))
        #expect(plugin.windows.last?.items.count == 1 && plugin.windows.last?.pane.fileCounter.count == 1)
        #expect(plugin.windows.last?.pane.handleKey(try key("n", [])) == false)
        // Without anything marked, F3 shows the file under the cursor.
        bench.left.model.clearSelection()
        bench.left.moveCursor(toName: "page.html")
        commands.perform(.view)
        #expect(plugin.windows.last?.items.map { $0.url?.lastPathComponent } == ["page.html"])
    }
}
