import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The window driven without being shown: its form, a search from start to finish, and what
/// the buttons below the list do.
@MainActor
@Suite
internal final class FindFilesWindow {
    /// One list the stand-in for the list plugin was asked to show.
    internal struct ShownList {
        /// The files of the list.
        internal let files: [URL]
        /// Its title.
        internal let title: String
        /// The panel it was to be shown in.
        internal let panel: any PanelHandle
    }

    /// Stands in for the plugin that shows file lists as folders, and notes what it was asked to show.
    internal final class Lists: FileListService {
        /// What it was asked to show, in order.
        internal var shown: [ShownList] = []

        /// Notes the list.
        internal func show(_ files: [URL], title: String, in panel: any PanelHandle) {
            shown.append(ShownList(files: files, title: title, panel: panel))
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The file system the panels show.
    internal let memory = MemoryFileSystem()
    /// The plugin under test.
    internal let plugin = FindFilesPlugin()
    /// The program around the plugin.
    internal let bench: TestBench

    /// The window of `cm_SearchFor`.
    internal var window: FindFilesWindowController { plugin.mainWindow(in: bench.kernel) }

    /// A bench with files in `/A` and `/B` of memory.
    internal init() {
        memory.addFile("/A/one.txt", "first report")
        memory.addFile("/A/two.txt", "second")
        memory.addFile("/A/docs/one.txt", "first report")
        memory.addFile("/A/docs/three.md", "third report")
        memory.addFile("/B/x.txt", "x")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Fills the form like a user, runs the search and waits for its end.
    internal func search(_ change: (inout SearchSettings) -> Void) async {
        let shown = window
        shown.prepare(startingIn: bench.left.model.directory, includeHidden: false)
        var settings = shown.form.settings
        change(&settings)
        shown.form.settings = settings
        shown.startSearch()
        // The end comes over the main queue, shared with every other test: waited for, not timed.
        #expect(await RunLoopWait.until { !shown.isSearching })
    }

    /// The plugin registers its commands, keys, toolbar button and preferences.
    @Test
    internal func registersCommandsMenusAndPreferences() {
        #expect(bench.commands[.searchFor]?.title == "Find Files…" && bench.commands["cm_SearchStandalone"] != nil)
        #expect(bench.kernel.keyBindings.command(for: .f(7, .option)) == .searchFor)
        #expect(bench.kernel.keyBindings.command(for: .f(7, [.option, .shift])) == "cm_SearchStandalone")
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(bench.kernel.toolbar.defaultLayout.contains { $0?.command == .searchFor })
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Find Files"])
        #expect(!bench.commands.isEnabled("cm_SearchForInCurDir"))
        bench.left.moveCursor(toName: "docs")
        #expect(bench.commands.isEnabled("cm_SearchForInCurDir"))
    }

    /// The form gives back every setting it was given.
    @Test
    internal func theFormGivesBackWhatItWasGiven() {
        var settings = SearchSettings()
        (
            settings.searchFor, settings.searchIn, settings.namesAreRegex, settings.searchArchives,
            settings.useSpotlight
        ) = ("a.*", "/x;/y", true, true, true)
        (settings.depth, settings.findText, settings.text, settings.caseSensitive) = (2, true, "needle", true)
        settings.textOptions = TextSearchOptions(
            wholeWords: true,
            regex: true,
            notContaining: true,
            encodings: [.utf8, .utf16]
        )
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        settings.criteria = FileCriteria(
            dateFrom: day,
            dateTo: day.addingTimeInterval(86_399),
            notOlderThan: Age(3, .weeks),
            olderThan: Age(2, .hours),
            size: SizeRule(.greater, 1.5, .megabytes)
        )
        (settings.criteria.hidden, settings.criteria.directory, settings.criteria.executable) = (.set, .unset, .set)
        settings.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true)
        settings.fieldRules = FieldRules(
            isEnabled: true,
            matchAll: false,
            rules: [FieldRule("tc.size", .greater, "10"), FieldRule("tc.name", .regex, "^a")]
        )
        window.form.settings = settings
        #expect(window.form.settings == settings)
        window.form.settings = SearchSettings()
        #expect(window.form.settings == SearchSettings())
    }

    /// A search lists its hits under a summary, and its fields go into their histories.
    @Test
    internal func aSearchListsItsHitsUnderASummary() async {
        await search { $0.searchFor = "*.txt" }
        #expect(
            window.lines == [
                "[3 files and 0 directories found]", "mem:/A/one.txt", "mem:/A/two.txt", "mem:/A/docs/one.txt"
            ]
        )
        await search { $0.searchFor = "docs zzz" }
        #expect(window.lines == ["[0 files and 1 directories found]", "mem:/A/docs"])
        await search { $0.searchFor = "nothing-like-this" }
        #expect(window.lines == ["[No files found]"] && window.resultItems.isEmpty)
        // The fields went into their histories, in the plugin's settings.
        #expect(
            SearchStore(settings: bench.kernel.settings).history(.searchFor) == [
                "nothing-like-this", "docs zzz", "*.txt"
            ]
        )
    }

    /// The text, the depth and the start directories come from the form.
    @Test
    internal func textAndDepthComeFromTheForm() async {
        await search { ($0.findText, $0.text) = (true, "REPORT") }
        #expect(window.resultItems.map(\.url.path) == ["/A/one.txt", "/A/docs/one.txt", "/A/docs/three.md"])
        await search { ($0.findText, $0.text, $0.depth) = (true, "report", 0) }
        #expect(window.resultItems.map(\.url.path) == ["/A/one.txt"])
        await search { ($0.findText, $0.text, $0.searchIn) = (true, "x", "mem:/B;mem:/A/docs") }
        #expect(window.resultItems.map(\.url.path) == ["/B/x.txt"])
    }

    /// Duplicates are listed in groups, a dashed line between two, an empty line when copied.
    @Test
    internal func duplicatesAreListedInGroups() async {
        memory.addFile("/A/docs/two.txt", "second")
        await search { $0.duplicates = DuplicateOptions(isEnabled: true, sameContents: true) }
        // The files of a group are in the order of their full paths.
        #expect(
            window.lines == [
                "[4 files and 0 directories found]", "one.txt  -  mem:/A/docs/", "one.txt  -  mem:/A/",
                String(repeating: "- ", count: 40), "two.txt  -  mem:/A/docs/", "two.txt  -  mem:/A/"
            ]
        )
        #expect(window.copyText.components(separatedBy: "\n")[3].isEmpty)
    }

    /// A form that cannot be searched with is reported and starts nothing.
    @Test
    internal func aFormThatCannotBeSearchedWithIsReported() async {
        await search { ($0.findText, $0.text, $0.textOptions.hex) = (true, "xyz", true) }
        #expect(
            bench.interaction.log == ["inform: The search cannot start"] && !window.isSearching && window.lines.isEmpty
        )
    }

    /// "Only search in selected" searches the marked items of the panel.
    @Test
    internal func onlySelectedItemsOfThePanel() async {
        bench.left.model.select(mask: "docs two.txt")
        await search { ($0.searchFor, $0.onlySelected) = ("*.txt", true) }
        #expect(window.resultItems.map(\.url.path) == ["/A/two.txt", "/A/docs/one.txt"])
    }

    /// Go to file takes the only result, also when the summary is the selected line.
    @Test
    internal func goToFilePutsThePanelOnTheResult() async {
        let navigation = bench.kernel.commands
        var went: [URL] = []
        navigation.register(Command(.changeDirectory, "cd")) { argument in
            went += [argument.location].compactMap(\.self)
        }
        await search { $0.searchFor = "three" }
        // The only result is taken although the summary line could be the selected one.
        window.goToFile()
        #expect(went == [memory.url("/A/docs/three.md")])
    }

    /// Feed to listbox hands the results to the list service and keeps none.
    @Test
    internal func feedToListboxHandsTheResultsToTheListService() async {
        await search { $0.searchFor = "one" }
        // Without a plugin that shows lists, nothing happens.
        window.feedToListbox()
        #expect(window.resultItems.count == 2)
        let lists = Lists()
        bench.kernel.services.register((any FileListService).self, lists)
        bench.right.focus()
        window.feedToListbox()
        #expect(
            lists.shown.count == 1 && lists.shown[0].title == "Search result" && lists.shown[0].panel === bench.right
        )
        #expect(lists.shown[0].files == [memory.url("/A/one.txt"), memory.url("/A/docs/one.txt")])
        // Fed results are not kept in the window.
        #expect(window.lines.isEmpty)
    }

    /// New search empties the list and keeps the form.
    @Test
    internal func newSearchEmptiesTheList() async {
        await search { $0.searchFor = "one" }
        window.newSearch()
        #expect(window.lines.isEmpty && window.form.settings.searchFor == "one")
    }

    /// The window goes with the test: drawn later, its list would ask a kernel that is gone.
    isolated deinit {
        autoreleasepool { plugin.stop() }
    }
}
