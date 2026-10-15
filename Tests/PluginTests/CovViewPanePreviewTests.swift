import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Quick Look previews in a Lister pane that leaves its window, or that never was in one: a
/// preview closed outside a window ends the program, so none is.
@MainActor
@Suite(.serialized)
internal struct CovViewPanePreviewTests {
    private static func hasPreview(_ view: NSView) -> Bool {
        view.subviews.contains { String(describing: type(of: $0)).contains("QLPreviewView") || hasPreview($0) }
    }

    /// A pane that leaves its window closes its preview while it is still in it, and shows the
    /// preview again when it is put back.
    @Test
    internal func aPaneThatLeavesItsWindowClosesItsPreviewThere() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("slides.key", text: "not really slides")))
        #expect(pane.mode == .preview)
        #expect(await bench.wait { Self.hasPreview(pane) })
        let window = try #require(pane.window)
        window.contentView = NSView()
        #expect(!Self.hasPreview(pane) && pane.mode == .preview)
        // Shown again in a window: the preview is made anew.
        window.contentView = pane
        #expect(await bench.wait { Self.hasPreview(pane) })
        // Another file: the preview goes, closed in the window.
        pane.load(ViewerItem(source: .text("words"), title: "Words"))
        #expect(await bench.wait { pane.loaded != nil && !Self.hasPreview(pane) })
    }

    /// A preview made for a pane that is in no window is let go without being closed.
    @Test
    internal func aPreviewOutsideAWindowIsLetGo() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = ViewerPane(
            kernel: bench.setup.bench.kernel,
            settings: bench.settings,
            temporaryCopies: TemporaryCopies(),
            isEmbedded: true
        )
        bench.prepare(pane)
        let slides = try bench.file("slides.key", text: "not really slides")
        pane.load(ViewerItem(source: .file(slides), title: "slides"))
        #expect(await bench.wait { Self.hasPreview(pane) })
        #expect(pane.window == nil)
        pane.clear()
        #expect(!Self.hasPreview(pane))
        // A pane without a preview leaves no window and joins none for it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.contentView = nil
        #expect(!Self.hasPreview(pane))
    }
}
