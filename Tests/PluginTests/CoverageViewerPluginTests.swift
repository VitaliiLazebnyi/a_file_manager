import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The viewer plugin: before it starts, its commands for the quick views, its configuration,
/// quitting, and volumes that are let go of.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPluginTests {
    /// A plugin that was never started opens nothing.
    @Test
    internal func aPluginThatWasNotStartedOpensNothing() {
        let plugin = ViewerPlugin(showsWindows: false)
        plugin.view(text: "text", title: "Note")
        plugin.view(URL(fileURLWithPath: "/tmp/file.txt"))
        #expect(plugin.windows.isEmpty)
    }

    /// Without a part of the target panel to cover, the quick view is refused.
    @Test
    internal func theQuickViewNeedsAPanelItCanCover() {
        let memory = MemoryFileSystem()
        memory.addFile("/A/a.txt", "a")
        let plugin = ViewerPlugin(quickViewDelay: 0.01, showsWindows: false)
        let bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/A"))
        var rejected = 0
        bench.commands.onRejected = { rejected += 1 }
        #expect(bench.commands.perform(.quickView))
        #expect(plugin.quickView == nil && rejected == 1)
    }

    /// With windows shown, a Lister window is put on screen (here: handed to the test, which
    /// keeps it off the screen).
    @Test
    internal func listerWindowsAreShownWhenAskedFor() async {
        let setup = CoverageViewerBench(left: nil, showsWindows: true)
        defer { setup.plugin.stop() }
        let presenter = StabilityPresenter()
        defer { presenter.closeAll() }
        setup.plugin.present = presenter.present
        setup.plugin.view(text: "shown", title: "Shown")
        let controller = setup.plugin.windows.last
        defer { controller?.close() }
        #expect(presenter.presented.count == 1 && presenter.presented.first === controller)
        #expect(presenter.isOpen(controller?.window) && controller?.window?.isVisible == false)
        controller?.close()
        #expect(await setup.wait { setup.plugin.windows.isEmpty })
    }

    /// The separate quick view, text only, follows the cursor; Reload asks again for what the
    /// cursor is on, and is offered only while a quick view is open.
    @Test
    internal func theSeparateQuickViewIsReloaded() async throws {
        let setup = CoverageViewerBench()
        defer { setup.plugin.stop() }
        #expect(!setup.commands.isEnabled(.updateQuickView))
        setup.bench.left.moveCursor(toName: "notes.txt")
        #expect(setup.commands.perform(.separateQuickViewInternalOnly))
        let window = try #require(setup.plugin.windows.first)
        #expect(window.followsCursor && window.pane.internalOnly)
        #expect(setup.commands.isEnabled(.updateQuickView))
        #expect(await setup.wait { window.pane.loaded != nil })
        window.pane.clear()
        #expect(setup.commands.perform(.updateQuickView))
        #expect(await setup.wait { window.pane.item?.url?.lastPathComponent == "notes.txt" })
    }

    /// A change on the preference page reaches the open panes.
    @Test
    internal func preferenceChangesReachTheOpenPanes() throws {
        let setup = CoverageViewerBench()
        defer { setup.plugin.stop() }
        setup.plugin.view(text: "text", title: "Text")
        let pane = try #require(setup.plugin.windows.first?.pane)
        #expect(pane.pager.showsCaret)
        setup.bench.kernel.settings.set(false, forKey: "viewer.caret")
        let page = try #require(setup.bench.kernel.preferences.pages.first { $0.title == "Lister" })
        page.onChange()
        #expect(!pane.pager.showsCaret)
    }

    /// Configure in a Lister window or in the quick view is the dialog of the command; what is
    /// answered is stored and taken over.
    @Test
    internal func configureFromAPaneStoresTheAnswers() throws {
        let setup = CoverageViewerBench()
        defer { setup.plugin.stop() }
        setup.plugin.view(text: "text", title: "Text")
        let pane = try #require(setup.plugin.windows.first?.pane)
        setup.interaction.formAnswers = [.values(["viewer.caret": .flag(false)])]
        pane.onConfigure()
        #expect(!ListerSettings(setup.bench.kernel.settings).caret && !pane.pager.showsCaret)
        let fields = try #require(setup.interaction.forms.last)
        #expect(fields.count == ListerSettings.preferences.count)
        #expect(setup.commands.perform(.quickView))
        let quick = try #require(setup.plugin.quickView)
        setup.interaction.formAnswers = [.values(["viewer.caret": .flag(true)])]
        quick.pane.onConfigure()
        #expect(ListerSettings(setup.bench.kernel.settings).caret && quick.pane.pager.showsCaret)
        // Cancelled, nothing changes.
        quick.pane.onConfigure()
        #expect(ListerSettings(setup.bench.kernel.settings).caret)
        #expect(setup.commands.perform(.hideQuickView))
    }

    /// Before quitting, the windows and the quick view close, and the copies are let go of in
    /// the background before the plugin says it is done.
    @Test
    internal func quittingClosesEverything() async {
        let setup = CoverageViewerBench()
        defer { setup.plugin.stop() }
        setup.plugin.view(text: "text", title: "Text")
        #expect(setup.commands.perform(.quickView))
        let done = ViewerAdoptBox(false)
        setup.plugin.prepareToQuit(cancellation: CancellationFlag()) { done.value = true }
        #expect(setup.plugin.windows.isEmpty && setup.plugin.quickView == nil)
        #expect(await setup.wait { done.value })
    }

    /// When a volume is let go of, the windows that show one of its files close, a quick view
    /// of one shows nothing, and the rest stays.
    @Test
    internal func lettingGoOfAVolumeClosesWhatShowsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-cov-viewer-volume-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("on-volume.txt")
        try Data("on the volume".utf8).write(to: file)
        let setup = CoverageViewerBench(left: folder, showsWindows: false)
        defer { setup.plugin.stop() }
        setup.plugin.view(file)
        setup.plugin.view(text: "elsewhere", title: "Elsewhere")
        setup.bench.left.moveCursor(toName: "on-volume.txt")
        #expect(setup.commands.perform(.quickView))
        let quick = try #require(setup.plugin.quickView)
        #expect(await setup.wait { quick.pane.item?.url?.lastPathComponent == "on-volume.txt" })
        setup.bench.kernel.fileSystems.releaseVolume(folder)
        #expect(setup.plugin.windows.count == 1 && setup.plugin.windows.first?.pane.item?.title == "Elsewhere")
        #expect(quick.pane.item == nil)
        // A quick view whose cursor is still on a file of the volume shows nothing, whatever it shows now.
        quick.pane.load(ViewerItem(source: .text("other"), title: "Other"))
        setup.bench.kernel.fileSystems.releaseVolume(folder)
        #expect(quick.pane.item == nil)
        #expect(setup.commands.perform(.hideQuickView))
    }
}
