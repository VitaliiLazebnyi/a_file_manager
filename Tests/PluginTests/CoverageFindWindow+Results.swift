import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The list of results: earlier searches, the cursor, keys and buttons, and what it is handed to.
extension CoverageFindWindow {
    // MARK: The results

    /// Directories are counted in the groups of duplicates.
    @Test
    internal func directoriesAreCountedInTheGroupsOfDuplicates() async {
        await search { settings in settings.duplicates = DuplicateOptions(isEnabled: true, sameName: true) }
        #expect(controller.lines.first == "[2 files and 0 directories found]")
    }

    /// The list of earlier searches is stepped through.
    @Test
    internal func theListOfEarlierSearchesIsSteppedThrough() async {
        await search { settings in settings.searchFor = "one" }
        await search { settings in settings.searchFor = "two" }
        #expect(button("<")?.isEnabled == true && button(">")?.isEnabled == false)
        press("<")
        #expect(controller.resultItems.map(\.name) == ["one.txt", "one.txt"] && status.contains("found"))
        press("<")
        press(">")
        #expect(controller.resultItems.map(\.name) == ["two.txt"])
        press(">")
        // Only the last ten are kept.
        for index in 0..<11 { await search { settings in settings.searchFor = "zz\(index)" } }
        for _ in 0..<12 { press("<") }
        #expect(controller.lines.first == "[No files found]")
        // The window keeps only the list on show when it closes.
        controller.close()
        press("<")
        #expect(button("<")?.isEnabled == false)
    }

    /// The cursor shows what the list does not.
    @Test
    internal func theCursorShowsWhatTheListDoesNot() async throws {
        await search { settings in settings.searchFor = "*" }
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

    /// The separator of duplicates is no row to choose.
    @Test
    internal func theSeparatorOfDuplicatesIsNoRowToChoose() async throws {
        memory.addFile("/A/docs/two.txt", "second")
        await search { settings in settings.duplicates = DuplicateOptions(isEnabled: true, sameContents: true) }
        let table = try #require(results)
        let separator = controller.lines.firstIndex { $0.hasPrefix("- -") } ?? 0
        #expect(!controller.tableView(table, shouldSelectRow: separator))
    }

    /// Keys of the result list.
    @Test
    internal func keysOfTheResultList() async throws {
        await search { settings in settings.searchFor = "two" }
        let table = try #require(results)
        table.selectRowIndexes([1], byExtendingSelection: false)
        table.keyDown(with: Controls.key(Controls.Code.character, "c", .command))
        #expect(scratch.pasteboard.string(forType: .string) == controller.copyText)
        table.keyDown(with: Controls.key(Controls.Code.functionKey3))
        table.keyDown(with: Controls.key(Controls.Code.functionKey4))
        #expect(performed.map(\.0) == [.view, .edit])
        // Another key goes to the list.
        table.keyDown(with: Controls.key(Controls.Code.downArrow))
        table.keyDown(with: Controls.key(Controls.Code.returnKey))
        #expect(performed.last?.0 == .changeDirectory)
    }

    /// View edit and go to file buttons.
    @Test
    internal func viewEditAndGoToFileButtons() async throws {
        await search { settings in settings.searchFor = "one" }
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

    /// A long list is copied in the background.
    @Test
    internal func aLongListIsCopiedInTheBackground() async throws {
        for index in 0..<20_001 { memory.addFile("/L/f\(index).txt") }
        await search(in: memory.url("/L")) { settings in settings.searchFor = "*.txt" }
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

    /// Feeding the results hands them on in a new tab.
    @Test
    internal func feedingTheResultsHandsThemOnInANewTab() async {
        await search { settings in settings.searchFor = "one" }
        let lists = Lists()
        bench.kernel.services.register((any FileListService).self, lists)
        controller.modifierFlags = { .shift }
        let tabs = bench.left.tabs.count
        press("Feed to listbox")
        #expect(lists.shown.count == 1 && bench.left.tabs.count == tabs + 1 && controller.lines.isEmpty)
    }

    /// Searching in the found files.
    @Test
    internal func searchingInTheFoundFiles() async {
        await search { settings in settings.searchFor = "*.txt" }
        #expect(button("F2 Search in found files/folders")?.isEnabled == true)
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.functionKey2))
        #expect(button("F2 Search in found files/folders")?.state == .on)
        controller.startSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.resultItems.count == 3)
        // Other keys are the window's as usual.
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.character, "q", .command))
        // Without results there is nothing to search in.
        controller.newSearch()
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.functionKey2))
        #expect(button("F2 Search in found files/folders")?.state == .off)
    }

    /// The selection of the panel is offered.
    @Test
    internal func theSelectionOfThePanelIsOffered() {
        bench.left.model.select(mask: "two.txt")
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(Controls.button("Only search in selected directories/files", in: content)?.isEnabled == true)
    }

    /// Results are not kept when the setting says so.
    @Test
    internal func resultsAreNotKeptWhenTheSettingSaysSo() async {
        await search { settings in settings.searchFor = "one" }
        bench.kernel.settings.set(false, forKey: FindFilesWindowController.keepResultsKey)
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        #expect(controller.lines.isEmpty)
    }

    /// Closing while searching drops the half list.
    @Test
    internal func closingWhileSearchingDropsTheHalfList() {
        memory.stallsListings = true
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        controller.startSearch()
        controller.close()
        #expect(!controller.isSearching && controller.lines.isEmpty)
        memory.stallsListings = false
    }
}
