import AFMContracts
import AFMKernel
import AppKit
import ClipboardPlugin
import FileOperationsPlugin
import FolderTabsPlugin
import LocalFileSystemPlugin
import MacIntegrationPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing
import ViewOptionsPlugin

@testable import FindFilesPlugin
@testable import ViewerPlugin

/// Every plugin driven through its commands, against a kernel with fake panels and a job
/// service that runs at once.
///
/// No window is put on screen: what the viewer and Find Files would show goes to `presenter` (none
/// of these commands opens a window of theirs).
@MainActor
@Suite
internal struct PluginCommandTests {
    /// The file system in memory the panels start in.
    ///
    /// `/A` holds `docs/in.txt`, `one.txt` and `two.txt`; `/B` holds an older `one.txt`.
    internal let memory = MemoryFileSystem()
    private let presenter = StabilityPresenter()
    /// The Mac integration plugin, which notes what it is asked to open instead of starting programs.
    internal let mac = MacIntegrationPlugin(launchesApplications: false)
    private let scratch = ScratchPasteboard()
    /// The pasteboard the clipboard plugin writes to, the test's own.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The kernel with every plugin, its fake panels and the job service that runs at once.
    internal let bench: TestBench

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, in focus at the start, showing `/A`.
    internal var left: FakePanel { bench.left }
    /// The right panel, showing `/B`.
    internal var right: FakePanel { bench.right }
    /// The user, as the test scripts them: the answers to give and a log of what was asked.
    internal var user: ScriptedInteraction { bench.interaction }

    /// Fills the file system in memory and starts every plugin on it.
    internal init() {
        memory.addFile("/A/one.txt", "new")
        memory.addFile("/A/two.txt", "2")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/B/one.txt", "old")
        let viewer = ViewerPlugin()
        viewer.present = presenter.present
        let find = FindFilesPlugin()
        find.present = presenter.present
        bench = TestBench(
            plugins: [
                NavigationPlugin(), viewer, mac, FileOperationsPlugin(), find,
                ClipboardPlugin(pasteboard: scratch.pasteboard), SelectionPlugin(), ViewOptionsPlugin(),
                FolderTabsPlugin()
            ],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Shows the folders `A` and `B` of `box` on the local disk in the left and the right panel.
    internal func showOnDisk(_ box: Sandbox) {
        left.show(box.url("A"))
        right.show(box.url("B"))
    }

    // MARK: Registration

    /// The plugins register their menus in order, a handler for each command in them, no key twice, file transfers.
    @Test
    internal func pluginsRegisterCommandsMenusAndServices() {
        #expect(left.names == ["docs", "one.txt", "two.txt"] && right.names == ["one.txt"])
        #expect(bench.kernel.menus.menus.map(\.title).starts(with: ["Files", "Edit", "Mark", "Commands", "Show"]))
        let inMenus =
            bench.kernel.menus.menus.flatMap(\.items).compactMap(\.self)
            + bench.kernel.menus.contextMenu(onItem: true).compactMap(\.self)
        // The names the window shell provides are the only ones without a handler here.
        #expect(inMenus.allSatisfy { commands[$0] != nil })
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(bench.kernel.services.find((any FileTransferService).self) != nil)
        // The Files menu keeps its order: open, transfer, create, delete, tools.
        let files = bench.kernel.menus.menus[0].items
        let expected: [CommandID] = [
            .open, .view, .edit, .copy, .copySamePanel, .renameMove, .renameOnly, .makeDirectory, .newTextFile,
            .delete, .deleteDirectly, .revealInFinder, .searchFor
        ]
        #expect(files.compactMap(\.self).filter(expected.contains) == expected && files.contains(nil))
        #expect(
            [CommandID.view, .edit, .copy, .renameMove, .makeDirectory, .delete].map { commands[$0]?.barLabel }
                == ["View", "Edit", "Copy", "Move", "NewFolder", "Delete"]
        )
    }

    // MARK: Selection

    /// Select all, invert, select and unselect a group by mask, and a cancelled prompt that marks nothing.
    @Test
    internal func selection() {
        commands.perform(.selectAll)
        #expect(left.model.selection.count == 3)
        commands.perform(.invertSelection)
        #expect(left.model.selection.isEmpty)
        user.promptAnswers = [.text("*.txt")]
        commands.perform(.selectGroup)
        #expect(left.model.selection == ["one.txt", "two.txt"])
        user.promptAnswers = [.text("two.*")]
        commands.perform(.unselectGroup)
        #expect(left.model.selection == ["one.txt"])
        user.promptAnswers = [.cancel]
        commands.perform(.selectGroup)
        commands.perform(.unselectAll)
        #expect(left.model.selection.isEmpty)
    }

    /// Commands that work on the whole list wait until the listing is complete; commands on named items do not.
    @Test
    internal func commandsThatMeanEverythingWaitForACompleteListing() throws {
        let listing = try PanelLoader.load(memory.url("/A"), showHidden: false, fileSystems: bench.kernel.fileSystems)
            .listing
        left.model.show(listing, complete: false)
        #expect(
            !commands.isEnabled(.selectAll) && !commands.isEnabled(.invertSelection)
                && !commands.isEnabled(.selectGroup)
        )
        // What is named explicitly can be worked on while the rest is arriving.
        left.moveCursor(toName: "one.txt")
        #expect(commands.isEnabled(.copy) && commands.isEnabled(.unselectAll))
        left.model.finishLoading()
        #expect(commands.isEnabled(.selectAll))
    }

    // MARK: Navigation

    /// Opening a folder, going to the parent, back, forward and to the root, and Enter where there is no parent row.
    @Test
    internal func navigation() {
        left.moveCursor(toName: "docs")
        commands.perform(.open)
        #expect(left.model.directory.path == "/A/docs" && left.names == ["in.txt"])
        commands.perform(.goToParent)
        #expect(left.model.directory.path == "/A" && left.model.cursorItem?.name == "docs")
        commands.perform(.goBack)
        #expect(left.model.directory.path == "/A/docs" && commands.isEnabled(.goForward))
        commands.perform(.goForward)
        #expect(left.model.directory.path == "/A" && !commands.isEnabled(.goForward))
        commands.perform(.goBack)
        commands.perform(.goToRoot)
        #expect(left.model.directory.path == "/" && left.model.cursorItem?.name == "A")
        #expect(!commands.isEnabled(.goToParent) && !commands.isEnabled(.goToRoot))
        // On [..] Enter goes up; here there is none, so nothing happens.
        left.model.moveCursor(to: 0)
        commands.perform(.open)
        #expect(left.model.directory.path == "/A")
    }

    /// Change Directory takes a location or typed text, Edit Path asks for one; a place that does not exist is refused.
    @Test
    internal func changeDirectoryTakesLocationsAndTypedText() {
        commands.perform(.changeDirectory, .location(memory.url("/B/one.txt")))
        #expect(left.model.directory.path == "/B" && left.model.cursorItem?.name == "one.txt")
        commands.perform(.changeDirectory, .text("../A/docs"))
        #expect(left.model.directory.path == "/A/docs")
        user.promptAnswers = [.text("/A")]
        commands.perform(.editPath)
        #expect(left.model.directory.path == "/A" && user.log.contains("prompt: Go to folder: [mem:/A/docs]"))
        // A place that does not exist leaves the panel where it was.
        commands.perform(.changeDirectory, .text("/nowhere"))
        #expect(left.model.directory.path == "/A" && left.failures.count == 1)
    }

    /// Target = Source, Exchange Panels and Reread work on the panels in focus.
    @Test
    internal func panelsFollowEachOther() {
        commands.perform(.targetEqualsSource)
        #expect(right.model.directory.path == "/A")
        left.show(memory.url("/A/docs"))
        commands.perform(.exchangePanels)
        #expect(left.model.directory.path == "/A" && right.model.directory.path == "/A/docs")
        memory.addFile("/A/from-outside.txt")
        commands.perform(.reread)
        #expect(left.names.contains("from-outside.txt"))
    }

    // MARK: Folder tabs

    /// New tab, open in new tab, next, activate and close tab, and the commands that need a folder or a second tab.
    @Test
    internal func folderTabs() {
        commands.perform(.newTab)
        #expect(left.tabs.count == 2 && left.tabs.activeIndex == 1 && left.names == ["docs", "one.txt", "two.txt"])
        left.moveCursor(toName: "docs")
        commands.perform(.openInNewTab)
        #expect(left.tabs.count == 3 && left.tabs.activeIndex == 1 && left.tabs.title(at: 2) == "docs")
        #expect(!left.tabs.tabs[2].isListed)
        commands.perform(.nextTab)
        #expect(left.model.directory.path == "/A/docs" && left.names == ["in.txt"])
        commands.perform(.activateTab, .index(0))
        #expect(left.tabs.activeIndex == 0)
        commands.perform(.closeTab, .index(2))
        commands.perform(.closeTab)
        #expect(left.tabs.count == 1 && !commands.isEnabled(.closeTab) && !commands.isEnabled(.nextTab))
        left.moveCursor(toName: "one.txt")
        #expect(!commands.isEnabled(.openInNewTab))
    }

    // MARK: View options

    /// Sorting by size, reversed and by name checks its command; Hidden Files shows and hides dot files in both panels.
    @Test
    internal func sortingAndHiddenFiles() {
        commands.perform(.sortBySize)
        #expect(left.model.sort == ListOrder(key: .size, descending: true) && commands.isChecked(.sortBySize))
        #expect(left.names == ["docs", "one.txt", "two.txt"])
        commands.perform(.reversedOrder)
        #expect(left.names == ["docs", "two.txt", "one.txt"] && !commands.isChecked(.reversedOrder))
        commands.perform(.sortByName)
        #expect(commands.isChecked(.sortByName) && !commands.isChecked(.sortBySize))

        memory.addFile("/A/.dotfile")
        memory.addFile("/B/.other")
        commands.perform(.showHidden)
        #expect(left.names.contains(".dotfile") && right.names.contains(".other") && commands.isChecked(.showHidden))
        commands.perform(.showHidden)
        #expect(!left.names.contains(".dotfile") && !right.names.contains(".other"))
    }
}
