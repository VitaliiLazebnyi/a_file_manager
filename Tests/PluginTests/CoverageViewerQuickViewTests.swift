import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The quick view over the right panel: its header and where the keyboard goes when it closes.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerQuickViewTests {
    /// A track that names itself replaces the file name in the header; the file's own name
    /// does not.
    @Test
    internal func aTrackNameReplacesTheFileName() async throws {
        let setup = CoverageViewerBench()
        setup.bench.left.moveCursor(toName: "notes.txt")
        #expect(setup.commands.perform(.quickView))
        let quick = try #require(setup.plugin.quickView)
        #expect(await setup.wait { quick.headerText == "notes.txt" })
        let path = setup.bench.kernel.fileSystems.displayPath(setup.memory.url("/A/notes.txt"))
        quick.pane.onTitleChange(path)
        #expect(quick.headerText == "notes.txt")
        quick.pane.onTitleChange("Track 1")
        #expect(quick.headerText == "Track 1")
        #expect(setup.commands.perform(.hideQuickView))
    }

    /// Closing a quick view that has the keyboard gives it back to the list it followed.
    @Test
    internal func theKeyboardGoesBackToTheFollowedList() throws {
        let setup = CoverageViewerBench()
        setup.bench.left.moveCursor(toName: "notes.txt")
        #expect(setup.commands.perform(.quickView))
        let quick = try #require(setup.plugin.quickView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = setup.rightHost.overlay
        #expect(window.makeFirstResponder(quick.pane))
        setup.bench.panelSet.source = setup.bench.right
        #expect(setup.commands.perform(.hideQuickView))
        #expect(setup.bench.panelSet.source === setup.bench.left)
        #expect(setup.rightHost.overlay == nil)
        window.close()
    }
}
