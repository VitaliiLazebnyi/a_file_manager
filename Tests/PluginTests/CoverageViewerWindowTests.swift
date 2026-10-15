import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Lister windows: their saved place, Esc, a session without files, and the separate quick
/// view that follows the panel cursor onto folders and `[..]`.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerWindowTests {
    private static func controller(
        _ setup: CoverageViewerBench,
        followsCursor: Bool = false
    ) -> ViewerWindowController {
        ViewerWindowController(
            kernel: setup.bench.kernel,
            settings: ListerSettings(setup.bench.kernel.settings),
            temporaryCopies: TemporaryCopies(),
            followsCursor: followsCursor,
            followDelay: 0.01
        ) { _ in
            // Nothing to forget.
        }
    }

    /// Waits for the main queue to run what is due in `seconds`, and what was due before.
    private static func settle(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.resume() }
        }
    }

    /// A window opens where it was saved, and Save position stores where it is.
    @Test
    internal func theWindowKeepsItsPlace() throws {
        let setup = CoverageViewerBench()
        let settings = ListerSettings(setup.bench.kernel.settings)
        settings.setWindowFrame(NSStringFromRect(NSRect(x: 40, y: 60, width: 500, height: 400)), quick: false)
        let controller = Self.controller(setup)
        let window = try #require(controller.window)
        #expect(window.frame.size == NSSize(width: 500, height: 400))
        window.setFrame(NSRect(x: 80, y: 90, width: 600, height: 450), display: false)
        controller.pane.onSavePosition()
        #expect(settings.windowFrame(quick: false) == NSStringFromRect(window.frame))
        #expect(settings.windowFrame(quick: true) == nil)
        controller.close()
    }

    /// Esc stops what runs first; with nothing running it is left to the window, and a window
    /// whose controller is gone leaves it too.
    @Test
    internal func escapeStopsTheActivityFirst() throws {
        let setup = CoverageViewerBench()
        var kept: ToolWindow?
        autoreleasepool {
            let controller = Self.controller(setup)
            kept = controller.window as? ToolWindow
            let flag = CancellationFlag()
            controller.pane.activity = ("Searching", nil, flag)
            #expect(kept?.onEscape?() == true && flag.isCancelled)
            controller.pane.activity = nil
            #expect(kept?.onEscape?() == false)
        }
        let window = try #require(kept)
        #expect(window.onEscape?() == false)
    }

    /// A session without files shows nothing and counts one place.
    @Test
    internal func aSessionWithoutFilesShowsNothing() {
        let setup = CoverageViewerBench()
        let controller = Self.controller(setup)
        controller.show([])
        #expect(controller.pane.item == nil && controller.pane.fileCounter == (0, 1))
        controller.close()
    }

    /// The separate quick view shows what a folder holds, nothing on `[..]`, and does not read
    /// the same item again when the cursor did not move.
    @Test
    internal func theSeparateQuickViewFollowsTheCursor() async {
        let setup = CoverageViewerBench()
        let controller = Self.controller(setup, followsCursor: true)
        let left = setup.bench.left
        left.moveCursor(toName: "folder")
        setup.bench.kernel.panelEvents.post(.cursorMoved, from: left)
        #expect(await setup.wait { controller.pane.folderSummary != nil })
        #expect(controller.window?.title.hasPrefix("Lister* - [") == true)
        #expect(controller.pane.folderSummary?.files == 1)
        // The same item again: nothing is read anew.
        let generation = controller.pane.loadGeneration
        setup.bench.kernel.panelEvents.post(.selectionChanged, from: left)
        await Self.settle(0.2)
        #expect(controller.pane.loadGeneration == generation)
        // Events of the other panel are not followed.
        setup.bench.kernel.panelEvents.post(.cursorMoved, from: setup.bench.right)
        left.model.moveCursor(to: 0)
        #expect(left.model.cursorItem == nil)
        setup.bench.kernel.panelEvents.post(.cursorMoved, from: left)
        #expect(await setup.wait { controller.window?.title == "Lister*" })
        #expect(controller.pane.item == nil && controller.pane.folderSummary == nil)
        controller.close()
    }

    /// The windows and views of the viewer are made in code only: an archive makes none.
    @Test
    internal func nothingIsMadeFromAnArchive() {
        #expect(ViewerWindowController(coder: NSCoder()) == nil)
        #expect(ViewerPane(coder: NSCoder()) == nil)
        #expect(TextPagerView(coder: NSCoder()) == nil)
        #expect(ImageCanvasView(coder: NSCoder()) == nil)
        #expect(MediaView(coder: NSCoder()) == nil)
        #expect(WebContentView(coder: NSCoder()) == nil)
        #expect(TextPrintView(coder: NSCoder()) == nil)
    }
}
