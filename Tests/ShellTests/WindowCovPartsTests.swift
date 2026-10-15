import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The parts of the window around the panels, each by itself: the folder watches, the changes
/// missed during a job, the command line's history, the layout, the divider, the tool windows
/// and the function-key bar.
@MainActor
@Suite(.serialized)
internal struct WindowCovPartsTests {
    /// A tool window that records what would close it instead of closing.
    private final class RecordingToolWindow: ToolWindow {
        /// How often it was asked to close as by its close button.
        var closeRequests = 0

        /// Recorded; the window stays.
        override func performClose(_: Any?) {
            closeRequests += 1
        }
    }

    /// A plugin with a command on F11 that the plain bar shows.
    private final class ElevenPlugin: Plugin {
        /// The plugin's name.
        let name = "Eleven"
        /// How often the command ran.
        var ran = 0

        /// Registers the command.
        func start(in kernel: Kernel) {
            kernel.commands.register(Command("cm_TestEleven", "Eleven", [.f(11)], barLabel: "Eleven")) { [self] in
                ran += 1
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Makes sure AppKit is there for the views.
    internal init() {
        _ = NSApplication.shared
    }

    /// A kernel with `fileSystem` registered.
    private static func kernel(with fileSystem: (any FileSystemProvider)? = nil) -> Kernel {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        fileSystem.map(kernel.fileSystems.register)
        return kernel
    }

    /// A folder no file system knows is not watched; a change reported for a folder that is no
    /// longer wanted is not passed on.
    @Test
    internal func onlyWantedFoldersOfKnownFileSystemsAreWatched() async throws {
        let fileSystem = PanelWatchedFileSystem()
        let kernel = Self.kernel(with: fileSystem)
        var changed: [[URL]] = []
        let watches = FolderWatches(fileSystems: kernel.fileSystems) { changed.append($0) }
        defer { watches.shutDown() }
        let nowhere = try #require(URL(string: "nowhere:/folder"))
        watches.watch(["nowhere": nowhere, "a": fileSystem.url("/a")])
        #expect(await AppWait.until { fileSystem.livingWatches == 1 })
        #expect(fileSystem.watches.map(\.path) == ["/a"])
        // (A watch that was slow to set up reports its folder once by itself: on a busy machine
        // that may come too.)
        fileSystem.reportChange(of: "/a")
        #expect(await AppWait.until { changed.contains { $0.map(\.path) == ["/a"] } })
        // No longer wanted: its changes are not heard of, and its watch ends.
        watches.watch([:])
        #expect(await AppWait.until { fileSystem.endedWatches == 1 })
        let heard = changed.count
        fileSystem.reportChange(of: "/a")
        await PanelWait.drainMainQueue()
        #expect(changed.count == heard)
    }

    /// Watches whose owner went away while they were being set up are let go of when they come.
    @Test
    internal func aWatchThatComesAfterItsOwnerWentIsLetGoOf() async {
        let fileSystem = PanelWatchedFileSystem()
        let kernel = Self.kernel(with: fileSystem)
        fileSystem.holdsWatches = true
        weak var gone: FolderWatches?
        do {
            let watches = FolderWatches(fileSystems: kernel.fileSystems) { _ in
                Issue.record("a change reached watches that went away")
            }
            watches.watch(["a": fileSystem.url("/a")])
            gone = watches
        }
        #expect(await AppWait.until { gone == nil && fileSystem.watches.count == 1 })
        fileSystem.holdsWatches = false
        #expect(await AppWait.until { fileSystem.endedWatches == 1 && fileSystem.livingWatches == 0 })
        // A change the file system still reports reaches nobody.
        fileSystem.reportChange(of: "/a")
        await PanelWait.drainMainQueue()
    }

    /// A watch that comes after the watches were shut down is let go of.
    @Test
    internal func aWatchThatComesAfterTheShutDownIsLetGoOf() async {
        let fileSystem = PanelWatchedFileSystem()
        let kernel = Self.kernel(with: fileSystem)
        fileSystem.holdsWatches = true
        let watches = FolderWatches(fileSystems: kernel.fileSystems) { _ in
            Issue.record("a change reached watches that were shut down")
        }
        watches.watch(["a": fileSystem.url("/a")])
        #expect(await AppWait.until { fileSystem.watches.count == 1 })
        watches.shutDown()
        fileSystem.holdsWatches = false
        #expect(await AppWait.until { fileSystem.endedWatches == 1 && fileSystem.livingWatches == 0 })
    }

    /// More folders than are noted one by one, or a change of everything, make everything to be
    /// looked at again; what comes after that is part of it.
    @Test
    internal func manyMissedChangesBecomeAll() {
        var missed = MissedChanges()
        #expect(missed.take() == nil)
        let folders = (0...MissedChanges.limit).map { URL(fileURLWithPath: "/folder\($0)") }
        missed.note(.only(folders), at: 1)
        missed.note(.only([URL(fileURLWithPath: "/later")]), at: 2)
        guard let taken = missed.take(), case .all = taken.changed else {
            Issue.record("everything is to be looked at again")
            return
        }
        #expect(taken.at == 2)
        missed.note(.all, at: 3)
        #expect(missed.take()?.at == 3 && missed.take() == nil)
    }

    /// A line of blanks is not remembered; switched off, remembering forgets what is stored even
    /// when nothing was loaded.
    @Test
    internal func blankLinesAreNotRememberedAndSwitchingOffForgetsTheStore() {
        let settings = MemorySettings()
        let history = CommandLineHistory(settings: settings)
        history.add("\u{00A0}\u{00A0}")
        #expect(history.entries.isEmpty)
        history.add("ls")
        settings.set(false, forKey: CommandLineHistory.recordKey)
        let reloaded = CommandLineHistory(settings: settings)
        #expect(reloaded.entries.isEmpty && settings.data(forKey: CommandLineHistory.settingsKey) == nil)
        // Stored by an older run while switched off, nothing in memory: it goes too.
        settings.set(["old"], forKey: CommandLineHistory.settingsKey)
        #expect(history.forgetIfSwitchedOff() && settings.data(forKey: CommandLineHistory.settingsKey) == nil)
        #expect(history.forgetIfSwitchedOff())
    }

    /// Setting the layout to what it is tells nobody; the layout page tells of changes.
    @Test
    internal func unchangedLayoutValuesTellNobody() {
        let layout = WindowLayout(settings: MemorySettings())
        var changes = 0
        layout.onChange = { changes += 1 }
        layout.isStacked = false
        layout.divider = layout.divider
        #expect(changes == 0)
        layout.isStacked = true
        layout.divider = 300
        #expect(changes == 2 && layout.divider == 300)
        layout.preferencePage().onChange()
        #expect(changes == 3)
    }

    /// Only a drag of the divider is remembered, as a share of the window; without a size the
    /// divider goes where it is put.
    @Test
    internal func onlyADraggedDividerIsRemembered() {
        let layout = WindowLayout(settings: MemorySettings())
        let split = PanelSplit(left: NSView(), right: NSView(), layout: layout)
        #expect(split.splitView(split.view, constrainSplitPosition: 5, ofSubviewAt: 0) == 5)
        split.view.frame = NSRect(x: 0, y: 0, width: 1_001, height: 601)
        split.apply()
        let dragged = Notification(
            name: NSSplitView.didResizeSubviewsNotification,
            object: split.view,
            userInfo: ["NSSplitViewDividerIndex": 0]
        )
        // Resized by the window, not dragged: nothing changes.
        split.splitViewDidResizeSubviews(dragged)
        #expect(layout.divider == 500)
        split.isDragging = { true }
        split.view.subviews[0].frame.size.width = 250
        split.splitViewDidResizeSubviews(dragged)
        #expect(layout.divider == 250)
        // One above the other, the height counts.
        layout.isStacked = true
        split.apply()
        split.view.subviews[0].frame.size.height = 420
        split.splitViewDidResizeSubviews(dragged)
        #expect(layout.divider == 700)
    }

    /// Esc closes a tool window unless its plugin used the key; ⌘W closes it; other keys go on.
    @Test
    internal func escAndCommandWCloseAToolWindow() {
        let window = RecordingToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.cancelOperation(nil)
        #expect(window.closeRequests == 1)
        window.onEscape = { true }
        window.cancelOperation(nil)
        window.onEscape = { false }
        window.cancelOperation(nil)
        #expect(window.closeRequests == 2)
        #expect(window.performKeyEquivalent(with: Controls.key(13, "w", .command)))
        #expect(!window.performKeyEquivalent(with: Controls.key(12, "q", .command)) && window.closeRequests == 3)
    }

    /// The function-key bar runs a button's command; the same modifiers shown again change nothing.
    @Test
    internal func theFunctionKeyBarRunsItsButtons() async throws {
        let fixture = try AppFixture(files: AppFixture.windowFiles)
        let plugin = ElevenPlugin()
        let app = await fixture.startWindow(with: plugin)
        defer { app.stop() }
        let bar = app.window.functionKeyBar
        let before = bar.buttons
        bar.show([])
        #expect(bar.buttons == before)
        let eleven = try #require(before.first { $0.title == "F11 Eleven" })
        Controls.send(eleven)
        #expect(plugin.ran == 1)
    }
}
