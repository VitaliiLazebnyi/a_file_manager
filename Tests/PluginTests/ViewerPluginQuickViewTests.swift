import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import ViewerPlugin

/// The quick view over a fake panel and the separate quick view window, following the cursor.
@MainActor
@Suite(.serialized)
internal struct ViewerPluginQuickViewTests: ViewerPluginFixture {
    /// The viewer and the program around it, made for this test.
    internal let setup: ViewerPluginSetup

    /// Makes the viewer over its files for this test.
    internal init() throws {
        setup = try ViewerPluginSetup()
    }

    // MARK: Quick view

    /// The quick view covers the other panel and follows the cursor, sums up folders, and goes with Ctrl+Q.
    @Test
    internal func theQuickViewCoversTheTargetPanelAndFollowsTheCursor() async throws {
        bench.left.moveCursor(toName: "short.txt")
        #expect(commands.perform(.quickView))
        let quick = try #require(plugin.quickView)
        #expect(
            try host(bench.right).overlay != nil && host(bench.left).overlay == nil && commands.isChecked(.quickView)
        )
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
                && quick.pane.item == nil
        )
        bench.left.show(memory.url("/A/docs"))
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        #expect(await wait { quick.shownItem == nil && quick.headerText.isEmpty && quick.pane.folderSummary == nil })
        bench.left.moveCursor(toName: "inner.txt")
        bench.kernel.panelEvents.post(.cursorMoved, from: bench.left)
        #expect(await wait { quick.pane.loaded?.item.url?.lastPathComponent == "inner.txt" })
        #expect(commands.isEnabled(.updateQuickView) && commands.perform(.updateQuickView))
        // Ctrl+Q again brings the file list back.
        #expect(commands.perform(.quickView))
        #expect(try plugin.quickView == nil && host(bench.right).overlay == nil && !commands.isChecked(.quickView))
    }

    /// Switching to the covered panel or changing its place ends the quick view; from the other side it covers the
    /// other panel.
    @Test
    internal func switchingToTheCoveredPanelOrChangingItsPlaceEndsTheQuickView() async throws {
        bench.left.moveCursor(toName: "short.txt")
        commands.perform(.quickView)
        #expect(plugin.quickView != nil)
        bench.kernel.panelEvents.post(.becameSource, from: bench.right)
        #expect(try plugin.quickView == nil && host(bench.right).overlay == nil)

        commands.perform(.quickViewInternalOnly)
        #expect(try plugin.quickView?.pane.internalOnly == true && host(bench.right).overlay != nil)
        bench.kernel.panelEvents.post(.locationChanged, from: bench.right)
        #expect(try plugin.quickView == nil && host(bench.right).overlay == nil)

        // From the other side it covers the other panel.
        bench.right.moveCursor(toName: "other.txt")
        bench.right.focus()
        commands.perform(.quickView)
        #expect(try host(bench.left).overlay != nil && host(bench.right).overlay == nil)
        #expect(await wait { plugin.quickView?.pane.loaded?.item.url?.lastPathComponent == "other.txt" })
        #expect(commands.perform(.hideQuickView))
        #expect(try plugin.quickView == nil && host(bench.left).overlay == nil)
        plugin.stop()
    }

    /// The separate quick view is a window that follows the cursor of whichever panel is the source.
    @Test
    internal func theSeparateQuickViewIsAWindowThatFollowsTheCursor() async throws {
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
