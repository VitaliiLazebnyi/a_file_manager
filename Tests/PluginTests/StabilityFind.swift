import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Searches at their edges: places the disk cannot describe, a cancel at the end of a listing
/// that came in parts, and answers that come after the window was closed.
@MainActor
@Suite(.serialized)
internal struct StabilityFind {
    /// The panels' file system, with three files of the same contents.
    internal let memory = MemoryFileSystem()
    /// A folder on the disk, for the questions to Spotlight.
    internal let box: Sandbox
    /// The kernel and its panels.
    internal let bench: TestBench
    /// The window, never put on screen.
    internal let controller: FindFilesWindowController
    /// Where the window would be put on screen.
    internal let presenter = StabilityPresenter()

    /// The files, the kernel and the window.
    internal init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        memory.addFile("/D/a.txt", "same")
        memory.addFile("/D/sub/a.txt", "same")
        memory.addFile("/D/sub/b.txt", "same")
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/D"),
            right: box.root
        )
        controller = FindFilesWindowController(kernel: bench.kernel)
        controller.present = presenter.present
    }

    /// Starts a search of `directory` as the form says after `change`.
    internal func start(in directory: URL, _ change: (inout SearchSettings) -> Void) {
        controller.prepare(startingIn: directory, includeHidden: false)
        var settings = controller.form.settings
        change(&settings)
        controller.form.settings = settings
        controller.startSearch()
    }

    // MARK: The search

    /// Overlapping start folders on a file system of local paths that the disk does not know:
    /// a file met by both is still reported once.
    @Test
    internal func overlappingPlacesTheDiskCannotDescribeReportEachFileOnce() {
        let paths = MemoryFileSystem(scheme: "file")
        let top = "/afm-nowhere-\(UUID().uuidString)"
        paths.addFile(top + "/a/one.txt")
        paths.addFile(top + "/b/two.txt")
        let registry = FileSystemRegistry()
        registry.register(paths)
        // Two start folders, the second also below the first with a depth that reaches it.
        var query = SearchQuery(directory: paths.url(top), names: "*.txt")
        query.moreDirectories = [paths.url(top + "/b")]
        query.maxDepth = 5
        var found: [String] = []
        FileSearch(query, fileSystems: registry).run { found.append($0.name) }
        #expect(found.sorted() == ["one.txt", "two.txt"])
    }

    /// A folder reported in parts whose listing finds the search cancelled at its end: what was
    /// reported stays, and the search ends.
    @Test
    internal func aCancelAtTheEndOfAListingInPartsEndsTheSearch() {
        let cancelling = StabilityFindCancellingListing()
        for name in ["a.txt", "b.txt", "c.txt"] { cancelling.base.addFile("/s/" + name) }
        let registry = FileSystemRegistry()
        registry.register(cancelling)
        let query = SearchQuery(directory: cancelling.base.url("/s"))
        let search = FileSearch(query, fileSystems: registry, tuning: FileSearch.Tuning(partialListingAfter: 1))
        var found: [String] = []
        search.run { found.append($0.name) }
        #expect(search.cancellation.isCancelled)
        #expect(Set(found).isSubset(of: ["a.txt", "b.txt", "c.txt"]))
    }

    // MARK: Answers after the window closed

    /// The status and the groups of a search for duplicates that come after the window was
    /// closed are dropped.
    @Test
    internal func duplicatesThatComeAfterTheWindowClosedAreDropped() async {
        memory.stallsReads = true
        start(in: memory.url("/D")) { $0.duplicates = DuplicateOptions(isEnabled: true, sameContents: true) }
        weak let running = controller.search
        // The walk is over and the comparing reads the first file: the status of the folder is
        // on its way to the main thread, which is held here until then.
        #expect(Wait.until { memory.stalledTransfers > 0 })
        controller.close()
        memory.stallsReads = false
        memory.releaseStalls()
        // The search is let go of once its last message to the window was dropped.
        #expect(await RunLoopWait.until { running == nil })
        #expect(controller.lines.isEmpty && !controller.isSearching)
    }

    /// Spotlight's answer that comes after the window was closed is dropped.
    @Test
    internal func anAnswerOfSpotlightAfterTheWindowClosedIsDropped() throws {
        let spotlight = StabilityFindSpotlight()
        controller.makeSpotlight = { _, _, _ in spotlight }
        try box.file("spot/x.txt")
        start(in: box.url("spot")) { $0.useSpotlight = true }
        #expect(spotlight.completion != nil && controller.isSearching)
        controller.close()
        #expect(spotlight.isStopped)
        spotlight.answer([box.url("spot/x.txt").path])
        #expect(controller.lines.isEmpty && !controller.isSearching)
    }

    /// The files of Spotlight's answer that are checked while the window closes are dropped.
    @Test
    internal func theFilesCheckedWhileTheWindowClosesAreDropped() async throws {
        let spotlight = StabilityFindSpotlight()
        controller.makeSpotlight = { _, _, _ in spotlight }
        try box.file("spot/x.txt")
        start(in: box.url("spot")) { $0.useSpotlight = true }
        weak let running = controller.search
        spotlight.answer([box.url("spot/x.txt").path])
        // The files are checked in the background; their list comes to a window that is closed.
        controller.close()
        #expect(await RunLoopWait.until { running == nil })
        #expect(controller.lines.isEmpty && !controller.isSearching)
    }

    /// A comparing rule on values that are not numbers compares them as text, ignoring case.
    @Test
    internal func valuesThatAreNoNumbersAreComparedAsText() {
        #expect(FieldRule("tc.name", .greater, "B").matches("c"))
        #expect(!FieldRule("tc.name", .less, "b").matches("C"))
        #expect(FieldRule("tc.name", .greaterOrEqual, "abc").matches("ABC"))
        #expect(FieldRule("tc.name", .lessOrEqual, "10").matches("9"))
    }

    // MARK: The form

    /// With no encoding ticked, the text is looked for in UTF-8.
    @Test
    internal func withoutAnEncodingTheTextIsUTF8() {
        let form = controller.form
        for button in form.tabView.tabViewItems.flatMap({ Controls.all(NSButton.self, in: $0.view) })
        where TextEncoding.allCases.contains(where: { $0.title == button.title }) {
            button.state = .off
        }
        #expect(form.settings.textOptions.encodings == [.utf8])
    }
}
