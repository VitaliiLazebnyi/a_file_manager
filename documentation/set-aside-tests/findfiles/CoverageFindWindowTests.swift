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
@MainActor @Suite(.serialized) final class CoverageFindWindow {
    /// A plugin that shows file lists, as the Lists plugin does.
    final class Lists: FileListService {
        var shown: [[URL]] = []
        func show(_ files: [URL], title _: String, in _: any PanelHandle) { shown.append(files) }
    }

    let memory = MemoryFileSystem()
    let box: Sandbox
    let bench: TestBench
    let controller: FindFilesWindowController
    let window: NSWindow
    let scratch = ScratchPasteboard()
    /// What the commands of the main window were asked to do.
    var performed: [(CommandID, URL?)] = []

    init() throws {
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
            bench.kernel.commands.register(Command(id, id.rawValue, keys), parameterized: { [weak self] argument in
                self?.performed.append((id, argument.location))
            })
        }
    }

    /// The window goes with the test.
    isolated deinit {
        // What closing hands to the autorelease pool is let go of while the window still lives.
        autoreleasepool { controller.close() }
    }

    var content: NSView? { window.contentView }
    var results: NSTableView? {
        Controls.all(NSTableView.self, in: content).first { $0.tableColumns.first?.identifier.rawValue == "path" }
    }
    var status: String {
        // The status line is the last line of the window; the cells of the list are cut in the middle too.
        Controls.all(NSTextField.self, in: content).last { $0.lineBreakMode == .byTruncatingMiddle }?.stringValue ?? ""
    }

    func button(_ title: String) -> NSButton? { Controls.button(title, in: content) }

    func press(_ title: String) {
        guard let button = button(title) else {
            Issue.record("no button \(title)")
            return
        }
        Controls.send(button)
    }

    /// Fills the form, starts the search and waits for its end.
    func search(in directory: URL? = nil, _ change: (inout SearchSettings) -> Void = { _ in }) async {
        controller.prepare(startingIn: directory ?? memory.url("/A"), includeHidden: false)
        var settings = controller.form.settings
        change(&settings)
        controller.form.settings = settings
        controller.startSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
    }

    // MARK: Searching

    @Test func theButtonsStartAndCancelASearch() async {
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

    @Test func escapeCancelsARunningSearchAndClosesOtherwise() async {
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

    @Test func aVolumeAboutToGoStopsTheSearchesThatReadIt() async {
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

    @Test func aSearchOfTheVolumeItselfIsStopped() async throws {
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

    @Test func typedPlacesAreTheUsersOwnChoice() async {
        await search { $0.searchIn = "mem:/A/docs" }
        #expect(controller.resultItems.map(\.name) == ["one.txt"])
    }

    @Test func aRunWithManyHitsArrivesInPieces() async {
        for index in 0..<2_100 { memory.addFile("/M/f\(index).txt") }
        await search(in: memory.url("/M")) { $0.searchFor = "*.txt" }
        #expect(controller.resultItems.count == 2_100 && controller.lines.first == "[2100 files and 0 directories found]")
    }

    @Test func slowFoldersAreShownWhileTheyAreSearched() async {
        memory.addFile("/S/a/x.txt")
        memory.addFile("/S/b/y.txt")
        memory.listStartDelay = 0.15
        defer { memory.listStartDelay = 0 }
        await search(in: memory.url("/S")) { $0.searchFor = "*.txt" }
        #expect(controller.resultItems.map(\.name) == ["x.txt", "y.txt"])
    }

    @Test func duplicatesTellHowFarTheComparingIs() async {
        memory.addFile("/D/a.txt", "same")
        memory.addFile("/D/sub/a.txt", "same")
        memory.listStartDelay = 0.15
        defer { memory.listStartDelay = 0 }
        await search(in: memory.url("/D")) { $0.duplicates = DuplicateOptions(isEnabled: true, sameContents: true) }
        #expect(controller.resultItems.count == 2)
    }

    @Test func aCancelledSearchKeepsWhatItFound() async {
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

    // MARK: The results

    @Test func directoriesAreCountedInTheGroupsOfDuplicates() async {
        await search { $0.duplicates = DuplicateOptions(isEnabled: true, sameName: true) }
        #expect(controller.lines.first == "[2 files and 0 directories found]")
    }

    @Test func theListOfEarlierSearchesIsSteppedThrough() async {
        await search { $0.searchFor = "one" }
        await search { $0.searchFor = "two" }
        #expect(button("<")?.isEnabled == true && button(">")?.isEnabled == false)
        press("<")
        #expect(controller.resultItems.map(\.name) == ["one.txt", "one.txt"] && status.contains("found"))
        press("<")
        press(">")
        #expect(controller.resultItems.map(\.name) == ["two.txt"])
        press(">")
        // Only the last ten are kept.
        for index in 0..<11 { await search { $0.searchFor = "zz\(index)" } }
        for _ in 0..<12 { press("<") }
        #expect(controller.lines.first == "[No files found]")
        // The window keeps only the list on show when it closes.
        controller.close()
        press("<")
        #expect(button("<")?.isEnabled == false)
    }

    @Test func theCursorShowsWhatTheListDoesNot() async throws {
        await search { $0.searchFor = "*" }
        let table = try #require(results)
        let folder = controller.lines.firstIndex { $0.hasSuffix("/A/docs") } ?? 1
        let changed = Notification(name: NSTableView.selectionDidChangeNotification, object: table)
        table.selectRowIndexes([folder], byExtendingSelection: false)
        controller.tableViewSelectionDidChange(changed)
        #expect(status.contains("<DIR>"))
        table.selectRowIndexes([0], byExtendingSelection: false)
        controller.tableViewSelectionDidChange(changed)
        #expect(status.hasPrefix("["))
        // A cell for every kind of line; the separator of duplicates cannot be selected.
        #expect(controller.tableView(table, shouldSelectRow: 1))
        let cell = controller.tableView(table, viewFor: nil, row: 0) as? NSTextField
        #expect(cell?.textColor == .secondaryLabelColor)
    }

    @Test func theSeparatorOfDuplicatesIsNoRowToChoose() async throws {
        memory.addFile("/A/docs/two.txt", "second")
        await search { $0.duplicates = DuplicateOptions(isEnabled: true, sameContents: true) }
        let table = try #require(results)
        let separator = controller.lines.firstIndex { $0.hasPrefix("- -") } ?? 0
        #expect(!controller.tableView(table, shouldSelectRow: separator))
    }

    @Test func keysOfTheResultList() async throws {
        await search { $0.searchFor = "two" }
        let table = try #require(results)
        table.selectRowIndexes([1], byExtendingSelection: false)
        table.keyDown(with: Controls.key(Controls.Code.character, "c", .command))
        #expect(scratch.pasteboard.string(forType: .string) == controller.copyText)
        table.keyDown(with: Controls.key(Controls.Code.f3))
        table.keyDown(with: Controls.key(Controls.Code.f4))
        #expect(performed.map(\.0) == [.view, .edit])
        // Another key goes to the list.
        table.keyDown(with: Controls.key(Controls.Code.down))
        table.keyDown(with: Controls.key(Controls.Code.returnKey))
        #expect(performed.last?.0 == .changeDirectory)
    }

    @Test func viewEditAndGoToFileButtons() async throws {
        await search { $0.searchFor = "one" }
        let table = try #require(results)
        table.selectRowIndexes([1], byExtendingSelection: false)
        press("F3 View")
        press("F4 Edit")
        #expect(performed.map(\.0) == [.view, .edit])
        // Shift goes to the file in a new tab.
        controller.modifierFlags = { .shift }
        let tabs = bench.left.tabs.count
        press("Go to file")
        #expect(performed.last?.0 == .changeDirectory && bench.left.tabs.count == tabs + 1)
        // Without a selection View and Edit do nothing, and with several results Go to file neither.
        table.deselectAll(nil)
        controller.form.settings = controller.form.settings
        press("F3 View")
        controller.goToFile()
        #expect(performed.count == 3)
    }

    @Test func aLongListIsCopiedInTheBackground() async throws {
        for index in 0..<20_001 { memory.addFile("/L/f\(index).txt") }
        await search(in: memory.url("/L")) { $0.searchFor = "*.txt" }
        let table = try #require(results)
        table.keyDown(with: Controls.key(Controls.Code.character, "c", .control))
        #expect(status == "[Copying the list...]", "\(status)")
        #expect(await RunLoopWait.until { self.scratch.pasteboard.string(forType: .string)?.isEmpty == false })
        #expect(status.hasPrefix("[20001 files"))
        // A copy overtaken by another drops its text.
        table.keyDown(with: Controls.key(Controls.Code.character, "c", .control))
        table.keyDown(with: Controls.key(Controls.Code.character, "c", .control))
        #expect(await RunLoopWait.until { self.status.hasPrefix("[20001 files") })
    }

    @Test func feedingTheResultsHandsThemOnInANewTab() async {
        await search { $0.searchFor = "one" }
        let lists = Lists()
        bench.kernel.services.register((any FileListService).self, lists)
        controller.modifierFlags = { .shift }
        let tabs = bench.left.tabs.count
        press("Feed to listbox")
        #expect(lists.shown.count == 1 && bench.left.tabs.count == tabs + 1 && controller.lines.isEmpty)
    }

    @Test func searchingInTheFoundFiles() async {
        await search { $0.searchFor = "*.txt" }
        #expect(button("F2 Search in found files/folders")?.isEnabled == true)
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.f2))
        #expect(button("F2 Search in found files/folders")?.state == .on)
        controller.startSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.resultItems.count == 3)
        // Other keys are the window's as usual.
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.character, "q", .command))
        // Without results there is nothing to search in.
        controller.newSearch()
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.f2))
        #expect(button("F2 Search in found files/folders")?.state == .off)
    }

    @Test func theSelectionOfThePanelIsOffered() {
        bench.left.model.select(mask: "two.txt")
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(Controls.button("Only search in selected directories/files", in: content)?.isEnabled == true)
    }

    @Test func resultsAreNotKeptWhenTheSettingSaysSo() async {
        await search { $0.searchFor = "one" }
        bench.kernel.settings.set(false, forKey: FindFilesWindowController.keepResultsKey)
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        #expect(controller.lines.isEmpty)
    }

    @Test func closingWhileSearchingDropsTheHalfList() async {
        memory.stallsListings = true
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        controller.startSearch()
        controller.close()
        #expect(!controller.isSearching && controller.lines.isEmpty)
        memory.stallsListings = false
    }

    // MARK: Spotlight

    @Test func spotlightIsAskedForLocalPlaces() async throws {
        try box.file("spot/spotlight-probe.txt", "x")
        await search(in: box.url("spot")) {
            ($0.useSpotlight, $0.searchFor) = (true, "spotlight-probe.txt")
        }
        #expect(controller.lines.first?.hasPrefix("[") == true)
        await search(in: box.url("spot")) {
            ($0.useSpotlight, $0.duplicates) = (true, DuplicateOptions(isEnabled: true, sameName: true))
        }
        #expect(controller.lines.first?.hasPrefix("[") == true)
        // Cancelled while Spotlight is asked: the list is empty.
        controller.prepare(startingIn: box.url("spot"), includeHidden: false)
        var settings = controller.form.settings
        settings.useSpotlight = true
        controller.form.settings = settings
        controller.startSearch()
        controller.cancelSearch()
        #expect(!controller.isSearching && controller.lines.first == "[Search cancelled]")
        controller.startSearch()
        controller.close()
        #expect(!controller.isSearching)
    }

    @Test func spotlightFindsWhatItHasIndexed() async {
        // The system's own applications are in the index on every Mac.
        await search(in: URL(fileURLWithPath: "/System/Applications")) {
            ($0.useSpotlight, $0.searchFor) = (true, "Calculator.app")
        }
        #expect(controller.resultItems.map(\.name) == ["Calculator.app"])
        // An answer cut short says so.
        controller.limits.spotlight = 1
        await search(in: URL(fileURLWithPath: "/System/Applications")) {
            ($0.useSpotlight, $0.searchFor) = (true, "*.app")
        }
        #expect(controller.lines.first?.contains("Spotlight gave more than 1 files") == true)
    }

    @Test func theNotesOfASearchThatDidNotGoAsAsked() async {
        controller.limits.results = 1
        await search { $0.searchFor = "*.txt" }
        #expect(controller.lines.first?.hasSuffix(" - stopped at 1 results]") == true)
        controller.limits.results = 100
        let slow = String(repeating: "a", count: 40)
        memory.addFile("/A/" + slow)
        await search {
            ($0.searchFor, $0.namesAreRegex) = ("(a*)*b", true)
        }
        #expect(controller.lines.first == "[No files found - a regular expression was too slow for some names]")
    }

    @Test func aCancelledSearchCountsWhatItFoundSoFar() async {
        for index in 0..<2_000 { memory.addFile("/K/f\(index).txt") }
        memory.addFile("/K/sub/late.txt")
        memory.stalledPaths = ["/K/sub"]
        memory.stallsListings = true
        defer { memory.stallsListings = false }
        controller.prepare(startingIn: memory.url("/K"), includeHidden: false)
        controller.startSearch()
        #expect(await RunLoopWait.until { self.controller.resultItems.count >= 2_000 })
        // While it runs, the cursor shows nothing more and a new search waits.
        results?.selectRowIndexes([1], byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        controller.newSearch()
        #expect(controller.resultItems.count >= 2_000)
        controller.cancelSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.lines.first?.hasPrefix("[Search cancelled, 2000 files") == true)
    }

    @Test func manyEarlierRowsAreLetGo() async {
        controller.limits.earlierRows = 3
        await search { $0.searchFor = "*.txt" }
        await search { $0.searchFor = "*.txt" }
        press("<")
        #expect(button("<")?.isEnabled == false)
    }

    @Test func duplicatesAtTheTopOfAFileSystem() async {
        memory.addFile("/same.txt", "s")
        memory.addFile("/A/same.txt", "s")
        await search(in: memory.url("/")) { $0.duplicates = DuplicateOptions(isEnabled: true, sameName: true) }
        #expect(controller.lines.contains("same.txt  -  \(bench.kernel.fileSystems.displayPath(memory.url("/")))"))
    }

    @Test func aSingleResultIsGoneToWithoutBeingChosen() async {
        await search { $0.searchFor = "two" }
        results?.deselectAll(nil)
        controller.goToFile()
        #expect(performed.last?.0 == .changeDirectory)
    }

    @Test func f2TurnsTheSearchInFoundFilesOnAndOff() async {
        await search { $0.searchFor = "*.txt" }
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.f2))
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.f2))
        #expect(button("F2 Search in found files/folders")?.state == .off)
        var closed = 0
        controller.onClose = { _ in closed += 1 }
        press("Close")
        #expect(closed == 1)
    }

    @Test func aPlaceTypedIntoTheFieldIsTheUsersChoice() async throws {
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        let searchIn = try #require(Controls.all(NSComboBox.self, in: content).dropFirst().first)
        searchIn.stringValue = "mem:/A/docs"
        controller.startSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.resultItems.map(\.name) == ["one.txt"])
    }

    @Test func aSearchInsideTheVolumeIsStopped() async throws {
        let folder = try box.folder("w/inner")
        controller.prepare(startingIn: folder, includeHidden: false)
        var settings = controller.form.settings
        (settings.findText, settings.text) = (true, "never")
        controller.form.settings = settings
        memory.stallsListings = true
        defer { memory.stallsListings = false }
        controller.startSearch()
        controller.cancelSearch(ifItReads: box.url("w"))
        #expect(await RunLoopWait.until { !self.controller.isSearching })
    }

    @Test func theWindowIsNeverMadeFromAnArchive() {
        #expect(FindFilesWindowController(coder: NSCoder()) == nil)
    }
}
