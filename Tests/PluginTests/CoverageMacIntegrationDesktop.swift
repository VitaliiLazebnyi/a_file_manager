import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MacIntegrationPlugin

/// What the Mac-integration plugin asks of the desktop, with a desktop that only notes it:
/// which files go to which application, what Finder shows, what the Quick Look panel is fed
/// and when it follows, the sharing panel and the choice of an application.
@MainActor
@Suite(.serialized)
internal struct CoverageMacIntegrationDesktop {
    /// The local files: `A` with two text files and a folder.
    private let box: Sandbox
    /// The clipboard the plugin writes to.
    private let scratch = ScratchPasteboard()
    /// The desktop that notes what it is asked.
    private let desktop = CoverageMacDesktop()
    /// The plugin under test.
    private let mac: MacIntegrationPlugin
    /// The kernel with the plugin.
    private let bench: TestBench

    /// The kernel's commands.
    private var commands: CommandRegistry { bench.commands }
    /// The panel on `A`.
    private var left: FakePanel { bench.left }
    /// What the desktop was asked.
    private var requests: [String] { desktop.requests.value }

    /// The files, the desktop and the kernel.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/notes.txt", "hello")
        try box.file("A/other.txt", "world")
        try box.folder("A/sub")
        try box.folder("B")
        let editor = URL(fileURLWithPath: "/Applications/First Editor.app")
        mac = MacIntegrationPlugin(desktop: desktop, pasteboard: scratch.pasteboard) { _ in [editor] }
        bench = TestBench(plugins: [mac], fileSystems: [LocalFileSystem()], left: box.url("A"), right: box.url("B"))
    }

    /// A window that is never put on screen.
    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// The path of a file in `A`.
    private func path(_ name: String) -> String { box.url("A/" + name).path }

    /// Opening with the default application, with one of the list, with one the user picks,
    /// and through the general opener.
    @Test
    internal func filesGoToTheirApplications() throws {
        left.moveCursor(toName: "notes.txt")
        commands.perform(MacIntegrationPlugin.openWithDefault)
        bench.interaction.formAnswers = [.values(["row": .index(0)]), .values(["row": .index(1)])]
        commands.perform(MacIntegrationPlugin.openWith)
        desktop.chosen = URL(fileURLWithPath: "/Applications/Picked.app")
        commands.perform(MacIntegrationPlugin.openWith)
        let item = try #require(left.model.cursorItem)
        #expect(bench.kernel.openers.open(item, in: left))
        #expect(
            requests == [
                "open " + path("notes.txt"), "open-with First Editor.app " + path("notes.txt"),
                "choose Choose an application", "open-with Picked.app " + path("notes.txt"), "open " + path("notes.txt")
            ]
        )
    }

    /// The editor is chosen by the user, and F4 hands the file to it.
    @Test
    internal func theEditorIsChosenAndUsed() {
        desktop.chosen = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        commands.perform(MacIntegrationPlugin.chooseEditor)
        #expect(
            bench.kernel.settings.text(MacIntegrationPlugin.editorKey, default: "")
                == "/System/Applications/TextEdit.app"
        )
        left.moveCursor(toName: "notes.txt")
        commands.perform(.edit)
        #expect(Wait.until { desktop.requests.value.last?.hasPrefix("open-with TextEdit.app") == true })
    }

    /// Finder is shown the marked items, or the folder itself.
    @Test
    internal func finderIsShownWhatIsMarked() {
        left.model.setSelected(true, names: ["notes.txt", "other.txt"])
        commands.perform(.revealInFinder)
        #expect(Wait.until { desktop.requests.value == ["reveal " + path("notes.txt") + " " + path("other.txt")] })
    }

    /// The sharing panel is offered the marked items.
    @Test
    internal func theMarkedItemsAreShared() {
        left.model.setSelected(true, names: ["notes.txt"])
        commands.perform(MacIntegrationPlugin.share)
        #expect(requests == ["share " + path("notes.txt")])
    }

    /// Without a window that has the keyboard (the program went to the background while a long
    /// list was gone through) the sharing panel is not shown; the log still says what was asked.
    @Test
    internal func withoutAKeyWindowNothingIsShared() {
        desktop.keyWindowContent = nil
        left.model.setSelected(true, names: ["notes.txt"])
        commands.perform(MacIntegrationPlugin.share)
        #expect(requests.isEmpty && mac.log == ["share " + path("notes.txt")])
    }

    /// The Quick Look feeder joins the responder chain of the main window when the command starts:
    /// a long marked list is gone through first, and the window is no longer the main one by the
    /// time the panel is shown.
    @Test
    internal func quickLookJoinsTheWindowTheCommandCameFrom() async throws {
        for index in 0...MacIntegrationPlugin.backgroundListThreshold { try box.file("A/many/f\(index).txt") }
        left.show(box.url("A/many"))
        left.model.selectAll()
        let window = Self.window()
        defer { window.close() }
        let before = window.nextResponder
        desktop.mainWindow = window
        commands.perform(MacIntegrationPlugin.quickLook)
        // The list is still being gone through: the main window goes.
        desktop.mainWindow = nil
        let panel = desktop.panel
        #expect(panel.calls.isEmpty)
        #expect(await RunLoopWait.until { panel.calls == ["show"] })
        let feeder = try #require(panel.feeder)
        #expect(window.nextResponder === feeder && feeder.nextResponder === before)
        #expect(feeder.numberOfPreviewItems(in: nil) == MacIntegrationPlugin.backgroundListThreshold + 1)
        mac.stop()
    }

    /// Quick Look: shown with the files, closed again; while open it follows the cursor and the
    /// marks of the active panel, and it closes for a drive that is released and when the
    /// plugin stops.
    @Test
    internal func quickLookShowsAndFollows() throws {
        let panel = desktop.panel
        left.moveCursor(toName: "notes.txt")
        commands.perform(MacIntegrationPlugin.quickLook)
        #expect(panel.calls == ["show"] && commands.isChecked(MacIntegrationPlugin.quickLook))
        let feeder = try #require(panel.feeder)
        #expect(feeder.numberOfPreviewItems(in: nil) == 1)
        commands.perform(MacIntegrationPlugin.quickLook)
        #expect(panel.calls == ["show", "close"] && !commands.isChecked(MacIntegrationPlugin.quickLook))
        commands.perform(MacIntegrationPlugin.quickLook)
        // The cursor moves: the panel shows the file under it.
        left.moveCursor(toName: "other.txt")
        bench.kernel.panelEvents.post(.cursorMoved, from: left)
        // The other panel moves: nothing changes.
        bench.kernel.panelEvents.post(.cursorMoved, from: bench.right)
        // Marked items are shown while they stay the same.
        left.model.setSelected(true, names: ["notes.txt", "other.txt"])
        bench.kernel.panelEvents.post(.selectionChanged, from: left)
        bench.kernel.panelEvents.post(.cursorMoved, from: left)
        #expect(panel.calls == ["show", "close", "show", "reload", "reload"])
        #expect(feeder.numberOfPreviewItems(in: nil) == 2)
        bench.kernel.fileSystems.releaseVolume(box.url("B"))
        #expect(panel.isVisible)
        bench.kernel.fileSystems.releaseVolume(box.url("A"))
        #expect(!panel.isVisible)
        commands.perform(MacIntegrationPlugin.quickLook)
        mac.stop()
        #expect(panel.calls.suffix(2) == ["show", "close"])
    }

    /// A very long marked list is followed from the background; an answer that comes when the
    /// panel has been closed meanwhile is dropped.
    @Test
    internal func longMarkedListsAreFollowedFromTheBackground() async throws {
        for index in 0...MacIntegrationPlugin.backgroundListThreshold { try box.file("A/many/f\(index).txt") }
        left.show(box.url("A/many"))
        left.moveCursor(toName: "f0.txt")
        let panel = desktop.panel
        commands.perform(MacIntegrationPlugin.quickLook)
        left.model.selectAll()
        bench.kernel.panelEvents.post(.selectionChanged, from: left)
        #expect(await RunLoopWait.until { panel.calls == ["show", "reload"] })
        left.model.setSelected(false, names: ["f0.txt"])
        bench.kernel.panelEvents.post(.selectionChanged, from: left)
        panel.close()
        // The answer asks whether the panel is still open, finds it closed and is dropped.
        let asked = panel.visibilityQuestions
        #expect(await RunLoopWait.until { panel.visibilityQuestions > asked })
        #expect(panel.calls == ["show", "reload", "close"])
    }

    /// The feeder joins the responder chain of a window once, feeds the panel by number, and
    /// passes keys on to what has the keys in that window.
    @Test
    internal func theFeederPassesKeysOn() throws {
        let feeder = QuickLookController()
        feeder.join(nil)
        #expect(feeder.nextResponder == nil && feeder.acceptsPreviewPanelControl(nil))
        let (window, other) = (Self.window(), Self.window())
        defer {
            window.close()
            other.close()
        }
        let keys = CoverageMacKeys(frame: window.contentLayoutRect)
        window.contentView = keys
        window.makeFirstResponder(keys)
        feeder.join(window)
        feeder.join(nil)
        feeder.join(other)
        // Joined once: the first window keeps it.
        #expect(window.nextResponder === feeder && other.nextResponder !== feeder)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: false,
                keyCode: 7
            )
        )
        #expect(feeder.previewPanel(nil, handle: event) && keys.typed == ["x"])
        #expect(!feeder.previewPanel(nil, handle: nil))
        #expect(feeder.previewPanel(nil, previewItemAt: 0) == nil)
    }
}
