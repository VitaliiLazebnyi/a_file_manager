import AFMContracts
import AFMKernel
import AppKit
import ClipboardPlugin
import FileOperationsPlugin
import FindFilesPlugin
import FolderTabsPlugin
import LocalFileSystemPlugin
import MacIntegrationPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing
import ViewOptionsPlugin
import ViewerPlugin

/// Every plugin driven through its commands, against a kernel with fake panels and a job
/// service that runs at once. No window is involved.
@MainActor @Suite struct PluginCommands {
    let memory = MemoryFileSystem()
    let mac = MacIntegrationPlugin(launchesApplications: false)
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }
    var ui: ScriptedInteraction { bench.interaction }

    init() {
        memory.addFile("/A/one.txt", "new")
        memory.addFile("/A/two.txt", "2")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/B/one.txt", "old")
        bench = TestBench(
            plugins: [
                NavigationPlugin(), ViewerPlugin(), mac, FileOperationsPlugin(), FindFilesPlugin(),
                ClipboardPlugin(pasteboard: scratch.pasteboard), SelectionPlugin(), ViewOptionsPlugin(),
                FolderTabsPlugin()
            ],
            fileSystems: [LocalFileSystem(), memory], left: memory.url("/A"), right: memory.url("/B"))
    }

    /// Shows two folders of the local disk in the panels.
    func showOnDisk(_ box: Sandbox) {
        left.show(box.url("A"))
        right.show(box.url("B"))
    }

    // MARK: Registration

    @Test func pluginsRegisterCommandsMenusAndServices() {
        #expect(left.names == ["docs", "one.txt", "two.txt"] && right.names == ["one.txt"])
        #expect(bench.kernel.menus.menus.map(\.title).starts(with: ["Files", "Edit", "Mark", "Commands", "Show"]))
        let inMenus =
            bench.kernel.menus.menus.flatMap(\.items).compactMap { $0 }
            + bench.kernel.menus.contextMenu(onItem: true).compactMap { $0 }
        // The names the window shell provides are the only ones without a handler here.
        #expect(inMenus.allSatisfy { commands[$0] != nil })
        #expect(bench.kernel.keyBindings.conflicts.isEmpty)
        #expect(bench.kernel.services.find((any FileTransferService).self) != nil)
        // The Files menu keeps its order: open, transfer, create, delete, tools.
        let files = bench.kernel.menus.menus[0].items
        let expected: [CommandID] = [
            .open, .view, .edit, .copy, .copySamePanel, .renameMove, .renameOnly, .makeDirectory, .newTextFile,
            .delete, .deleteDirectly, .revealInFinder, .searchFor
        ]
        #expect(files.compactMap { $0 }.filter(expected.contains) == expected && files.contains(nil))
        #expect(
            [CommandID.view, .edit, .copy, .renameMove, .makeDirectory, .delete].map { commands[$0]?.barLabel }
                == ["View", "Edit", "Copy", "Move", "NewFolder", "Delete"])
    }

    // MARK: Selection

    @Test func selection() {
        commands.perform(.selectAll)
        #expect(left.model.selection.count == 3)
        commands.perform(.invertSelection)
        #expect(left.model.selection.isEmpty)
        ui.promptAnswers = [.text("*.txt")]
        commands.perform(.selectGroup)
        #expect(left.model.selection == ["one.txt", "two.txt"])
        ui.promptAnswers = [.text("two.*")]
        commands.perform(.unselectGroup)
        #expect(left.model.selection == ["one.txt"])
        ui.promptAnswers = [.cancel]
        commands.perform(.selectGroup)
        commands.perform(.unselectAll)
        #expect(left.model.selection.isEmpty)
    }

    @Test func commandsThatMeanEverythingWaitForACompleteListing() throws {
        let listing = try PanelLoader.load(memory.url("/A"), showHidden: false, fileSystems: bench.kernel.fileSystems)
            .listing
        left.model.show(listing, complete: false)
        #expect(
            !commands.isEnabled(.selectAll) && !commands.isEnabled(.invertSelection)
                && !commands.isEnabled(.selectGroup))
        // What is named explicitly can be worked on while the rest is arriving.
        left.moveCursor(toName: "one.txt")
        #expect(commands.isEnabled(.copy) && commands.isEnabled(.unselectAll))
        left.model.finishLoading()
        #expect(commands.isEnabled(.selectAll))
    }

    // MARK: Navigation

    @Test func navigation() {
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

    @Test func changeDirectoryTakesLocationsAndTypedText() {
        commands.perform(.changeDirectory, .location(memory.url("/B/one.txt")))
        #expect(left.model.directory.path == "/B" && left.model.cursorItem?.name == "one.txt")
        commands.perform(.changeDirectory, .text("../A/docs"))
        #expect(left.model.directory.path == "/A/docs")
        ui.promptAnswers = [.text("/A")]
        commands.perform(.editPath)
        #expect(left.model.directory.path == "/A" && ui.log.contains("prompt: Go to folder: [mem:/A/docs]"))
        // A place that does not exist leaves the panel where it was.
        commands.perform(.changeDirectory, .text("/nowhere"))
        #expect(left.model.directory.path == "/A" && left.failures.count == 1)
    }

    @Test func panelsFollowEachOther() {
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

    @Test func folderTabs() {
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

    // MARK: File operations

    @Test func copyAsksForTheTargetAndAboutOverwriting() {
        left.moveCursor(toName: "one.txt")
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [0]
        commands.perform(.copy)
        #expect(ui.log.contains("prompt: Copy \"one.txt\" to [mem:/B/one.txt]"))
        #expect(ui.log.contains { $0.hasPrefix("choose: Overwrite:") })
        #expect(memory.contents("/B/one.txt") == "new")
        #expect(bench.jobService.titles == ["Copy:"] && !bench.jobService.reports.isEmpty)
    }

    @Test func copyingASelectionDeselectsItAndRefreshesTheTarget() {
        commands.perform(.selectAll)
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [1]
        commands.perform(.copy)
        #expect(ui.log.contains("prompt: Copy 3 file(s) to [mem:/B/*.*]"))
        #expect(memory.contents("/B/docs/in.txt") == "inside" && memory.exists("/B/two.txt"))
        #expect(left.model.selection.isEmpty && right.names == ["docs", "one.txt", "two.txt"])
        commands.perform(.restoreSelection)
        #expect(left.model.selection.count == 3)
    }

    @Test func copyInTheSameFolderPutsTheCursorOnTheCopy() {
        left.moveCursor(toName: "two.txt")
        ui.promptAnswers = [.text("two copy.txt")]
        commands.perform(.copySamePanel)
        #expect(ui.log.contains("prompt: Copy \"two.txt\" to [two.txt]"))
        #expect(memory.contents("/A/two copy.txt") == "2" && left.model.cursorItem?.name == "two copy.txt")
    }

    @Test func copyingOntoItselfIsRefusedWithAMessage() {
        left.moveCursor(toName: "two.txt")
        ui.promptAnswers = [.text("/A/")]
        commands.perform(.copy)
        #expect(ui.log.last == "inform: You cannot copy a file to itself!")
        #expect(left.names == ["docs", "one.txt", "two.txt"])
    }

    @Test func moveAndRename() {
        left.moveCursor(toName: "two.txt")
        ui.promptAnswers = [.accept]
        commands.perform(.renameMove)
        #expect(memory.exists("/B/two.txt") && !memory.exists("/A/two.txt") && right.names == ["one.txt", "two.txt"])

        left.moveCursor(toName: "one.txt")
        commands.perform(.renameOnly, .text("renamed.txt"))
        #expect(memory.contents("/A/renamed.txt") == "new" && left.model.cursorItem?.name == "renamed.txt")

        // A name that is taken is refused, the file stays, and the user is told.
        memory.addFile("/A/taken.txt", "t")
        left.reload()
        left.moveCursor(toName: "renamed.txt")
        commands.perform(.renameOnly, .text("taken.txt"))
        #expect(ui.log.last == "inform: renamed.txt cannot be renamed!")
        #expect(memory.contents("/A/taken.txt") == "t" && memory.contents("/A/renamed.txt") == "new")
        #expect(left.model.cursorItem?.name == "renamed.txt")
    }

    @Test func newFolders() {
        left.moveCursor(toName: "docs")
        ui.promptAnswers = [.text("made/inner | other")]
        commands.perform(.makeDirectory)
        #expect(ui.log.contains("prompt: New folder (directory) [docs]"))
        #expect(memory.exists("/A/made/inner") && memory.exists("/A/other") && left.model.cursorItem?.name == "other")
        ui.promptAnswers = [.text("docs")]
        commands.perform(.makeDirectory)
        #expect(ui.log.last == "inform: The folder docs cannot be created!")
    }

    @Test func deleteAsksAndDeletesDirectlyWhereThereIsNoTrash() {
        left.moveCursor(toName: "docs")
        ui.choiceAnswers = [0, 0]
        commands.perform(.delete)
        // This file system has no Trash, so F8 deletes for good and says so.
        #expect(
            ui.log.contains("choose: Permanently delete / Do you really want to delete the selected directory docs?"))
        #expect(ui.log.contains { $0.hasPrefix("choose: The directory mem:/A/docs is not empty!") })
        #expect(!memory.exists("/A/docs") && left.names == ["one.txt", "two.txt"])

        left.moveCursor(toName: "one.txt")
        ui.choiceAnswers = [1]
        commands.perform(.deleteDirectly)
        #expect(memory.exists("/A/one.txt"))
    }

    @Test func onAReadOnlyFileSystemChangingCommandsAreWithheld() {
        memory.capabilities = []
        left.moveCursor(toName: "one.txt")
        for command in [
            CommandID.renameMove, .renameOnly, .makeDirectory, .newTextFile, .delete, .deleteDirectly, .copySamePanel
        ] {
            #expect(!commands.isEnabled(command), "\(command) should be disabled")
        }
        // Copying out of it is still possible.
        #expect(commands.isEnabled(.copy))
    }

    @Test func nothingIsOfferedOnTheParentRow() {
        left.model.moveCursor(to: 0)
        #expect(left.model.cursorIsOnParentRow)
        for command in [CommandID.copy, .renameMove, .renameOnly, .delete, .view, .edit, .cutToClipboard] {
            #expect(!commands.isEnabled(command), "\(command) should be disabled")
        }
        #expect(commands.isEnabled(.makeDirectory) && commands.isEnabled(.open))
    }

    // MARK: On the local disk: Trash, editor, clipboard

    @Test func newTextFileIsCreatedAndHandedToTheEditor() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        showOnDisk(box)
        ui.promptAnswers = [.text("notes.txt")]
        commands.perform(.newTextFile)
        #expect(box.read("A/notes.txt") == "" && left.model.cursorItem?.name == "notes.txt")
        #expect(mac.opened.map(\.lastPathComponent) == ["notes.txt"])
    }

    @Test func openingAFileGoesToTheOpeners() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        showOnDisk(box)
        left.moveCursor(toName: "readme.md")
        commands.perform(.open)
        commands.perform(.edit)
        commands.perform(.edit, .location(box.url("A/other.txt")))
        #expect(mac.opened.map(\.lastPathComponent) == ["readme.md", "readme.md", "other.txt"])

        // A file no plugin opens: the command is rejected, nothing else happens.
        var rejections = 0
        commands.onRejected = { rejections += 1 }
        left.show(memory.url("/A"))
        left.moveCursor(toName: "one.txt")
        commands.perform(.open)
        #expect(rejections == 1 && !commands.isEnabled(.edit))
    }

    @Test func deleteMovesToTheTrashOnTheLocalDisk() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        showOnDisk(box)
        left.moveCursor(toName: "readme.md")
        ui.choiceAnswers = [1]
        commands.perform(.delete)
        #expect(ui.log.contains("choose: Test / Do you really want to move the selected file readme.md to the Trash?"))
        #expect(box.exists("A/readme.md"))
    }

    @Test func clipboardCopiesMovesAndRenamesSelfCopies() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/docs/in.txt", "2")
        try box.folder("B")
        showOnDisk(box)
        #expect(!commands.isEnabled(.pasteFromClipboard))

        commands.perform(.selectAll)
        commands.perform(.copyToClipboard)
        #expect(left.model.selection.count == 2)
        right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(box.read("B/one.txt") == "1" && box.read("B/docs/in.txt") == "2" && right.names == ["docs", "one.txt"])

        // Pasted next to the original, a copy gets a new name.
        left.focus()
        commands.perform(.pasteFromClipboard)
        #expect(box.read("A/one (2).txt") == "1" && box.exists("A/docs (2)/in.txt"))

        // Cut and paste moves, once.
        commands.perform(.unselectAll)
        left.moveCursor(toName: "one (2).txt")
        commands.perform(.cutToClipboard)
        right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(box.read("B/one (2).txt") == "1" && !box.exists("A/one (2).txt"))
        #expect(left.names == ["docs", "docs (2)", "one.txt"])

        commands.perform(.copyFullNames)
        #expect(pasteboard.string(forType: .string) == box.url("B").path + "/one (2).txt")
    }

    @Test func theClipboardCarriesLocalFilesOnly() {
        left.moveCursor(toName: "one.txt")
        #expect(!commands.isEnabled(.copyToClipboard) && !commands.isEnabled(.cutToClipboard))
        commands.perform(.copyFullNames)
        #expect(pasteboard.string(forType: .string) == "mem:/A/one.txt")
    }

    // MARK: View options

    @Test func sortingAndHiddenFiles() {
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
