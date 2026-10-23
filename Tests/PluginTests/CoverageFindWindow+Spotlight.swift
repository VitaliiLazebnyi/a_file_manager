import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Spotlight, the notes of searches that did not go as asked, and the edges of searching.
extension CoverageFindWindow {
    // MARK: Spotlight

    /// Spotlight is asked for local places.
    @Test
    internal func spotlightIsAskedForLocalPlaces() async throws {
        try box.file("spot/spotlight-probe.txt", "x")
        await search(in: box.url("spot")) { settings in
            (settings.useSpotlight, settings.searchFor) = (true, "spotlight-probe.txt")
        }
        #expect(controller.lines.first?.hasPrefix("[") == true)
        await search(in: box.url("spot")) { settings in
            (settings.useSpotlight, settings.duplicates) = (true, DuplicateOptions(isEnabled: true, sameName: true))
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

    /// Spotlight finds what it has indexed.
    @Test
    internal func spotlightFindsWhatItHasIndexed() async {
        // The system's own applications are in the index on every Mac.
        await search(in: URL(fileURLWithPath: "/System/Applications")) { settings in
            (settings.useSpotlight, settings.searchFor) = (true, "Calculator.app")
        }
        #expect(controller.resultItems.map(\.name) == ["Calculator.app"])
        // An answer cut short says so.
        controller.limits.spotlight = 1
        await search(in: URL(fileURLWithPath: "/System/Applications")) { settings in
            (settings.useSpotlight, settings.searchFor) = (true, "*.app")
        }
        #expect(controller.lines.first?.contains("Spotlight gave more than 1 files") == true)
    }

    /// The notes of a search that did not go as asked.
    @Test
    internal func theNotesOfASearchThatDidNotGoAsAsked() async {
        controller.limits.results = 1
        await search { settings in settings.searchFor = "*.txt" }
        #expect(controller.lines.first?.hasSuffix(" - stopped at 1 results]") == true)
        controller.limits.results = 100
        let slow = String(repeating: "a", count: 40)
        memory.addFile("/A/" + slow)
        await search { settings in
            (settings.searchFor, settings.namesAreRegex) = ("(a*)*b", true)
        }
        #expect(controller.lines.first == "[No files found - a regular expression was too slow for some names]")
    }

    /// A cancelled search counts what it found so far.
    @Test
    internal func aCancelledSearchCountsWhatItFoundSoFar() async {
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

    /// Many earlier rows are let go.
    @Test
    internal func manyEarlierRowsAreLetGo() async {
        controller.limits.earlierRows = 3
        await search { settings in settings.searchFor = "*.txt" }
        await search { settings in settings.searchFor = "*.txt" }
        press("<")
        #expect(button("<")?.isEnabled == false)
    }

    /// Duplicates at the top of a file system.
    @Test
    internal func duplicatesAtTheTopOfAFileSystem() async {
        memory.addFile("/same.txt", "s")
        memory.addFile("/A/same.txt", "s")
        await search(in: memory.url("/")) { settings in
            settings.duplicates = DuplicateOptions(isEnabled: true, sameName: true)
        }
        #expect(controller.lines.contains("same.txt  -  \(bench.kernel.fileSystems.displayPath(memory.url("/")))"))
    }

    /// A single result is gone to without being chosen.
    @Test
    internal func aSingleResultIsGoneToWithoutBeingChosen() async {
        await search { settings in settings.searchFor = "two" }
        results?.deselectAll(nil)
        controller.goToFile()
        #expect(performed.last?.0 == .changeDirectory)
    }

    /// F2 turns the search in found files on and off.
    @Test
    internal func f2TurnsTheSearchInFoundFilesOnAndOff() async {
        await search { settings in settings.searchFor = "*.txt" }
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.functionKey2))
        _ = window.performKeyEquivalent(with: Controls.key(Controls.Code.functionKey2))
        #expect(button("F2 Search in found files/folders")?.state == .off)
        var closed = 0
        controller.onClose = { _ in closed += 1 }
        press("Close")
        #expect(closed == 1)
    }

    /// A place typed into the field is the users choice.
    @Test
    internal func aPlaceTypedIntoTheFieldIsTheUsersChoice() async throws {
        controller.prepare(startingIn: memory.url("/A"), includeHidden: false)
        let searchIn = try #require(Controls.all(NSComboBox.self, in: content).dropFirst().first)
        searchIn.stringValue = "mem:/A/docs"
        controller.startSearch()
        #expect(await RunLoopWait.until { !self.controller.isSearching })
        #expect(controller.resultItems.map(\.name) == ["one.txt"])
    }

    /// A search inside the volume is stopped.
    @Test
    internal func aSearchInsideTheVolumeIsStopped() async throws {
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

    /// The window is never made from an archive.
    @Test
    internal func theWindowIsNeverMadeFromAnArchive() {
        #expect(FindFilesWindowController(coder: NSCoder()) == nil)
    }
}
