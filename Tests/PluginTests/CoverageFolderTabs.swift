import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FolderTabsPlugin

/// The corners of the tab commands the other suites leave out: the lists of each side, going
/// back a tab, dialogs that are cancelled, and tab files that cannot be read or written.
@MainActor
@Suite
internal struct CoverageFolderTabs {
    /// The files: `/A` with two folders, `/B` with one file.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The plugin under test.
    private let plugin = FolderTabsPlugin()
    /// The kernel with the plugin; the panels show `/A` and `/B`.
    private let bench: TestBench

    /// The kernel's commands.
    private var commands: CommandRegistry { bench.commands }
    /// The panel on `/A`, the source.
    private var left: FakePanel { bench.left }
    /// The panel on `/B`.
    private var right: FakePanel { bench.right }
    /// The dialogs, answered by script.
    private var dialogs: ScriptedInteraction { bench.interaction }

    /// The files and the kernel.
    internal init() {
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/A/pics/cat.jpg", "meow")
        memory.addFile("/B/other.txt", "o")
        files = CoverageSmallFiles(memory)
        bench = TestBench(plugins: [plugin], fileSystems: [files], left: memory.url("/A"), right: memory.url("/B"))
    }

    /// The paths of a panel's tabs.
    private func paths(_ panel: FakePanel) -> [String] { panel.tabs.tabs.map(\.directory.path) }

    /// Previous Tab goes back to the tab on the left, and round to the last one.
    @Test
    internal func previousTabGoesToTheTabOnTheLeft() {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: false)
        commands.perform(.previousTab)
        #expect(left.tabs.activeIndex == 1)
        commands.perform(.previousTab)
        #expect(left.tabs.activeIndex == 0)
    }

    /// The tab lists of the left and the right panel activate a tab of that panel.
    @Test
    internal func eachSideHasItsTabList() {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: false)
        right.tabs.openTab(showing: memory.url("/A/pics"), activate: false)
        dialogs.formAnswers = [.values(["row": .index(1)]), .values(["row": .index(1)])]
        commands.perform("cm_LeftTabsList")
        commands.perform("cm_RightTabsList")
        #expect(left.tabs.activeIndex == 1 && right.tabs.activeIndex == 1)
        #expect(dialogs.log == ["form: Open tabs", "form: Open tabs"])
    }

    /// A cancelled list of closed tabs reopens nothing.
    @Test
    internal func aCancelledListOfClosedTabsReopensNothing() {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: false)
        commands.perform(.closeTab, .index(1))
        dialogs.formAnswers = [.cancel]
        commands.perform("afm_RecentlyClosedTabs")
        #expect(paths(left) == ["/A"] && commands.isEnabled("afm_ReopenClosedTab"))
    }

    /// An empty name given as a parameter gives the tab its folder's name back; a cancelled
    /// dialog changes nothing.
    @Test
    internal func anEmptyNameRestoresTheTitleAndACancelledDialogChangesNothing() {
        left.model.customTitle = "Mine"
        commands.perform("cm_RenameTab", .text(""))
        #expect(left.model.customTitle == nil && left.tabs.title(at: 0) == "A")
        left.model.customTitle = "Kept"
        dialogs.formAnswers = [.cancel]
        commands.perform("cm_RenameTab")
        #expect(left.model.customTitle == "Kept" && dialogs.log == ["form: Rename tab"])
    }

    /// A tab file with a sort key this program does not know sorts by name.
    @Test
    internal func anUnknownSortKeySortsByName() {
        memory.addFile("/B/odd.tab", "[activetabs]\n0_path=mem:/A/docs\n0_options=1|99|1|0|0|0|0\nactivetab=0\n")
        commands.perform("OPENTABS", .location(memory.url("/B/odd.tab")))
        #expect(paths(left) == ["/A/docs"] && left.model.sort == ListOrder(key: .name, descending: true))
    }

    /// Loading asks for the file; cancelled, nothing is loaded.
    ///
    /// A folder is not a tab file.
    @Test
    internal func loadingIsCancelledOrRefusesAFolder() {
        dialogs.promptAnswers = [.cancel]
        commands.perform("APPENDTABS")
        #expect(bench.jobService.titles.isEmpty && dialogs.log == ["prompt: Load tabs from file: [mem:/A/tabs.tab]"])
        commands.perform("OPENTABS", .location(memory.url("/A/docs")))
        #expect(dialogs.log.last == "inform: The tabs could not be loaded." && paths(left) == ["/A"])
    }

    /// A tab file that cannot be written is reported, and no part of it is left behind.
    @Test
    internal func aTabFileThatCannotBeWrittenIsReported() {
        files.fails = [.write]
        commands.perform("SAVETABS", .location(memory.url("/B/mine.tab")))
        #expect(dialogs.log == ["inform: The tabs could not be saved."])
        #expect(memory.allPaths.filter { $0.hasPrefix("/B/") } == ["/B/other.txt"])
    }

    /// A location connects when its file system says so, or by its scheme; a text without a
    /// scheme is no location that connects.
    @Test
    internal func whatConnectsToAServer() {
        #expect(!plugin.connects("") && !plugin.connects("relative/path") && plugin.connects("sftp://host/x"))
        #expect(!plugin.connects(memory.url("/A").absoluteString))
        files.connectsToServer = true
        #expect(plugin.connects(memory.url("/A").absoluteString))
    }
}
