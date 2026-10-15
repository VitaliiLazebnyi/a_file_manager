import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import Quartz
import TestSupport
import Testing

@testable import MacIntegrationPlugin

/// The feeder of the Quick Look panel on its own, the panel following a cursor that leaves the
/// local disks, and the plugin as the program makes it. No panel is put on screen.
@MainActor
@Suite(.serialized)
internal struct CovMacQuickLookTests {
    /// A feeder with a panel that is only a state.
    private static func feeder() -> (QuickLookController, CoverageMacPreview) {
        let panel = CoverageMacPreview()
        let feeder = QuickLookController()
        feeder.panel = panel
        return (feeder, panel)
    }

    /// Nothing to show shows nothing; the files shown are handed to the panel by their place;
    /// following the same files asks the panel for nothing, other files make it ask again.
    @Test
    internal func theFeederShowsAndFollowsFiles() throws {
        let (feeder, panel) = Self.feeder()
        feeder.toggle([])
        #expect(panel.calls.isEmpty && !feeder.isVisible)
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")
        feeder.toggle([first])
        #expect(panel.calls == ["show"] && feeder.numberOfPreviewItems(in: nil) == 1)
        let item = try #require(feeder.previewPanel(nil, previewItemAt: 0))
        #expect(item.previewItemURL == first)
        #expect(feeder.previewPanel(nil, previewItemAt: 1) == nil)
        feeder.follow([first])
        #expect(panel.calls == ["show"])
        feeder.follow([second])
        #expect(panel.calls == ["show", "reload"])
        #expect(try #require(feeder.previewPanel(nil, previewItemAt: 0)).previewItemURL == second)
        feeder.close()
        #expect(panel.calls.last == "close" && !feeder.isVisible)
    }

    /// The system's panel takes the feeder as its source and delegate while it is in control,
    /// and lets go of it afterwards; the panel is never put on screen.
    @Test
    internal func theSystemPanelIsFedWhileInControl() throws {
        let (feeder, _) = Self.feeder()
        let panel = try #require(QLPreviewPanel.shared())
        defer { panel.orderOut(nil) }
        #expect(feeder.acceptsPreviewPanelControl(panel))
        feeder.beginPreviewPanelControl(panel)
        #expect(panel.dataSource === feeder && panel.delegate === feeder)
        feeder.endPreviewPanelControl(panel)
        #expect(panel.dataSource == nil && panel.delegate == nil && !panel.isVisible)
    }

    /// The open panel follows the cursor onto a file system that is not the local disk: it shows
    /// nothing of it.
    @Test
    internal func aCursorOffTheLocalDiskShowsNothing() throws {
        let box = try Sandbox()
        try box.file("A/notes.txt", "hello")
        let memory = MemoryFileSystem()
        memory.addFile("/M/remote.txt", "far away")
        let desktop = CoverageMacDesktop()
        let mac = MacIntegrationPlugin(desktop: desktop, pasteboard: ScratchPasteboard().pasteboard) { _ in [] }
        let bench = TestBench(
            plugins: [mac],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: memory.url("/M")
        )
        defer { mac.stop() }
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(MacIntegrationPlugin.quickLook)
        let feeder = try #require(desktop.panel.feeder)
        #expect(feeder.numberOfPreviewItems(in: nil) == 1)
        bench.left.show(memory.url("/M"))
        bench.left.moveCursor(toName: "remote.txt")
        bench.kernel.panelEvents.post(.cursorMoved, from: bench.left)
        #expect(feeder.numberOfPreviewItems(in: nil) == 0 && desktop.panel.calls == ["show", "reload"])
    }

    /// The plugin the program makes hands its requests to the Mac's desktop; made and let go
    /// of, it has asked nothing.
    @Test
    internal func theProgramsPluginIsMadeQuietly() {
        weak var gone: MacIntegrationPlugin?
        autoreleasepool {
            let plugin = MacIntegrationPlugin()
            #expect(plugin.opened.isEmpty && plugin.log.isEmpty && plugin.name == "Mac integration")
            gone = plugin
        }
        #expect(gone == nil)
    }
}
