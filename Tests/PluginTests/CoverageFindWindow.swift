import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The Find Files window driven through its buttons, keys and form, without being shown:
/// searches that run, are cancelled or stopped, the list of earlier results, and what the
/// results are handed to.
///
/// The tests of the results and of Spotlight are in the extensions.
@MainActor
@Suite(.serialized)
internal final class CoverageFindWindow {
    /// A plugin that shows file lists, as the Lists plugin does.
    internal final class Lists: FileListService {
        /// The lists it was given, in order.
        internal var shown: [[URL]] = []

        /// Takes the list.
        internal func show(_ files: [URL], title _: String, in _: any PanelHandle) { shown.append(files) }

        deinit {
            // Nothing to release.
        }
    }

    /// The panels' file system: two files, the same text in a subfolder, an empty folder.
    internal let memory = MemoryFileSystem()
    /// A folder on the disk, for Spotlight and the volume tests.
    internal let box: Sandbox
    /// The kernel and its panels.
    internal let bench: TestBench
    /// The window's controller.
    internal let controller: FindFilesWindowController
    /// The window, never put on screen.
    internal let window: NSWindow
    /// The pasteboard the window copies to.
    internal let scratch = ScratchPasteboard()
    /// What the commands of the main window were asked to do.
    internal var performed: [(CommandID, URL?)] = []
    /// No window of Find Files is put on screen or left open.
    internal let watch = StabilityWindows { $0.title.hasPrefix("Find Files") }

    /// What the window shows.
    internal var content: NSView? { window.contentView }
    /// The list of results.
    internal var results: NSTableView? {
        Controls.all(NSTableView.self, in: content).first { $0.tableColumns.first?.identifier.rawValue == "path" }
    }
    /// The status line under the list.
    internal var status: String {
        // The status line is the last line of the window; the cells of the list are cut in the middle too.
        Controls.all(NSTextField.self, in: content).last { $0.lineBreakMode == .byTruncatingMiddle }?.stringValue ?? ""
    }

    /// The window over the memory, its commands recorded.
    internal init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        memory.addFile("/A/one.txt", "first report")
        memory.addFile("/A/two.txt", "second")
        memory.addFile("/A/docs/one.txt", "first report")
        memory.addDirectory("/A/empty")
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/A")
        )
        controller = FindFilesWindowController(kernel: bench.kernel)
        window = try #require(controller.window)
        controller.pasteboard = scratch.pasteboard
        for (id, keys) in [(CommandID.view, [Shortcut.f(3)]), (.edit, [.f(4)]), (.changeDirectory, [])] {
            bench.kernel.commands.register(Command(id, id.rawValue, keys)) { [weak self] argument in
                self?.performed.append((id, argument.location))
            }
        }
    }

    /// The button with this title.
    internal func button(_ title: String) -> NSButton? { Controls.button(title, in: content) }

    /// Sends the action of the button with this title, as a click does.
    internal func press(_ title: String) {
        guard let button = button(title) else {
            Issue.record("no button \(title)")
            return
        }
        Controls.send(button)
    }

    /// Fills the form as `change` says, starts the search in `directory` and waits for its end.
    internal func search(in directory: URL, _ change: (inout SearchSettings) -> Void) async {
        controller.prepare(startingIn: directory, includeHidden: false)
        var settings = controller.form.settings
        change(&settings)
        controller.form.settings = settings
        controller.startSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
    }

    /// The same in the panels' folder.
    internal func search(_ change: (inout SearchSettings) -> Void) async {
        await search(in: memory.url("/A"), change)
    }

    // MARK: Searching

    /// The buttons start and cancel a search.
    @Test
    internal func theButtonsStartAndCancelASearch() async {
        memory.stallsListings = true
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        press("Start search")
        #expect(controller.isSearching && button("Cancel") != nil)
        // Pressed again while it runs, nothing new starts.
        press("Start search")
        controller.form.onSubmit?()
        press("Cancel")
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.lines.first?.hasPrefix("[Search cancelled") == true)
        memory.stallsListings = false
        controller.form.onSubmit?()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.lines.first == "[3 files and 2 directories found]")
    }

    /// Escape cancels a running search and closes otherwise.
    @Test
    internal func escapeCancelsARunningSearchAndClosesOtherwise() async {
        memory.stallsListings = true
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        controller.startSearch()
        window.cancelOperation(nil)
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        memory.stallsListings = false
        var closed = 0
        controller.onClose = { _ in closed += 1 }
        window.cancelOperation(nil)
        #expect(closed == 1)
    }

    /// A volume about to go stops the searches that read it.
    @Test
    internal func aVolumeAboutToGoStopsTheSearchesThatReadIt() async {
        memory.stallsListings = true
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        controller.cancelSearch(ifItReads: box.root)
        controller.startSearch()
        // A search of another place goes on.
        controller.cancelSearch(ifItReads: box.root)
        #expect(controller.isSearching)
        controller.cancelSearch(ifItReads: memory.url("/A"))
        #expect(controller.isSearching)
        controller.cancelSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        // A search whose places are not known is stopped: better a search again than a drive refused.
        var settings = controller.form.settings
        settings.searchIn = ""
        controller.form.settings = settings
        controller.startSearch()
        controller.cancelSearch(ifItReads: box.root)
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        memory.stallsListings = false
    }

    /// A search of the volume itself is stopped.
    @Test
    internal func aSearchOfTheVolumeItselfIsStopped() async throws {
        let folder = try box.folder("v")
        try box.file("v/x.txt")
        controller.prepare(startingIn: folder, includeHidden: false)
        var settings = controller.form.settings
        settings.findText = true
        settings.text = "never in any file"
        controller.form.settings = settings
        memory.stallsListings = true
        controller.startSearch()
        controller.cancelSearch(ifItReads: folder)
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        controller.cancelSearch(ifItReads: folder)
    }

    /// Typed places are the users own choice.
    @Test
    internal func typedPlacesAreTheUsersOwnChoice() async {
        await search { $0.searchIn = "mem:/A/docs" }
        #expect(controller.resultItems.map(\.name) == ["one.txt"])
    }

    /// A run with many hits arrives in pieces.
    @Test
    internal func aRunWithManyHitsArrivesInPieces() async {
        for index in 0..<2_100 { memory.addFile("/M/f\(index).txt") }
        await search(in: memory.url("/M")) { settings in settings.searchFor = "*.txt" }
        #expect(
            controller.resultItems.count == 2_100 && controller.lines.first == "[2100 files and 0 directories found]"
        )
    }

    /// Slow folders are shown while they are searched.
    @Test
    internal func slowFoldersAreShownWhileTheyAreSearched() async {
        memory.addFile("/S/a/x.txt")
        memory.addFile("/S/b/y.txt")
        memory.listStartDelay = 0.15
        defer { memory.listStartDelay = 0 }
        await search(in: memory.url("/S")) { settings in settings.searchFor = "*.txt" }
        #expect(controller.resultItems.map(\.name) == ["x.txt", "y.txt"])
    }

    /// Duplicates tell how far the comparing is.
    @Test
    internal func duplicatesTellHowFarTheComparingIs() async {
        memory.addFile("/D/a.txt", "same")
        memory.addFile("/D/sub/a.txt", "same")
        memory.listStartDelay = 0.15
        defer { memory.listStartDelay = 0 }
        await search(in: memory.url("/D")) { settings in
            settings.duplicates = DuplicateOptions(isEnabled: true, sameContents: true)
        }
        #expect(controller.resultItems.count == 2)
    }

    /// A cancelled search keeps what it found.
    @Test
    internal func aCancelledSearchKeepsWhatItFound() async {
        memory.addFile("/C/a.txt")
        memory.addFile("/C/sub/b.txt")
        memory.stalledPaths = ["/C/sub"]
        memory.stallsListings = true
        controller.prepare(startingIn: memory.url("/C"), includeHidden: false)
        controller.startSearch()
        controller.cancelSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.lines.first?.hasPrefix("[Search cancelled") == true)
        memory.stallsListings = false
    }

    /// The window goes with the test.
    isolated deinit {
        // What closing hands to the autorelease pool is let go of while the window still lives.
        autoreleasepool { controller.close() }
        if !watch.shown.isEmpty || !watch.open.isEmpty {
            Issue.record("Windows shown: \(watch.shown), left open: \(watch.openTitles)")
        }
        watch.closeAll()
    }
}
