import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Working with files and folders in the whole program, and changes other programs make.
@MainActor
@Suite(.serialized)
internal struct AppFileWorkTests {
    /// The program's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// Copying, renaming, moving, making a folder and deleting change the disk and both panels.
    @Test
    internal func copyMoveRenameAndDelete() async {
        let app = await fixture.startProgram()
        let user = fixture.user
        let box = fixture.box
        defer { app.stop() }
        app.cursor(app.left, on: "one.txt")
        user.promptAnswers = [.accept]
        user.choiceAnswers = [0]
        app.commands.perform(.copy)
        #expect(app.kernel.jobs.isBusy && !app.commands.isEnabled(.delete))
        await app.settle()
        #expect(user.log.contains("prompt: Copy \"one.txt\" to [\(box.url("B").path)/one.txt]"))
        #expect(box.read("B/one.txt") == "new")

        app.commands.perform(.selectAll)
        user.promptAnswers = [.accept]
        user.choiceAnswers = [1]
        app.commands.perform(.copy)
        await app.settle()
        #expect(box.read("B/docs/in.txt") == "inside" && box.exists("B/two.txt"))
        #expect(app.left.model.selection.isEmpty && app.names(app.right) == ["docs", "one.txt", "two.txt"])
        #expect(fixture.namesOnDisk("B") == ["docs", "one.txt", "two.txt"])

        app.cursor(app.left, on: "two.txt")
        app.commands.perform(.renameOnly, .text("renamed.txt"))
        await app.settle()
        #expect(
            box.exists("A/renamed.txt") && !box.exists("A/two.txt") && app.left.model.cursorItem?.name == "renamed.txt"
        )
        user.promptAnswers = [.accept]
        app.commands.perform(.renameMove)
        await app.settle()
        #expect(
            box.exists("B/renamed.txt") && !box.exists("A/renamed.txt") && app.names(app.right).contains("renamed.txt")
        )

        user.promptAnswers = [.text("made/inner")]
        app.commands.perform(.makeDirectory)
        await app.settle()
        #expect(box.exists("A/made/inner") && app.left.model.cursorItem?.name == "made")
        user.choiceAnswers = [0, 0]
        app.commands.perform(.deleteDirectly)
        await app.settle()
        #expect(!box.exists("A/made") && !app.names(app.left).contains("made"))
        app.cursor(app.left, on: "one.txt")
        user.choiceAnswers = [1]
        app.commands.perform(.deleteDirectly)
        await app.settle()
        #expect(box.exists("A/one.txt"))
    }

    /// Opening, going up and back, and folder tabs that are read when they are first shown.
    @Test
    internal func navigationAndFolderTabs() async {
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.cursor(app.left, on: "docs")
        app.commands.perform(.open)
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "docs" && app.names(app.left) == ["in.txt"])
        app.commands.perform(.goToParent)
        await app.settle()
        #expect(app.left.model.cursorItem?.name == "docs")
        app.commands.perform(.goBack)
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "docs")
        app.commands.perform(.changeDirectory, .location(fixture.box.url("B/one.txt")))
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "B" && app.left.model.cursorItem?.name == "one.txt")
        app.commands.perform(.goBack)
        await app.settle()
        app.commands.perform(.goToParent)
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "A")

        app.commands.perform(.newTab)
        #expect(app.left.tabs.count == 2 && app.left.tabs.activeIndex == 1)
        app.cursor(app.left, on: "docs")
        app.commands.perform(.openInNewTab)
        #expect(app.left.tabs.count == 3 && app.left.tabs.activeIndex == 1 && !app.left.tabs.tabs[2].isListed)
        app.commands.perform(.nextTab)
        await app.settle()
        // The background tab is read when it is shown for the first time.
        #expect(app.left.model.directory.lastPathComponent == "docs" && app.names(app.left) == ["in.txt"])
        #expect(app.left.tableView.numberOfRows == 2)
        app.commands.perform(.closeTab)
        app.commands.perform(.closeTab)
        await app.settle()
        #expect(
            app.left.tabs.count == 1 && app.left.model.directory.lastPathComponent == "A"
                && !app.commands.isEnabled(.closeTab)
        )
        app.shell.saveState()
        #expect(fixture.settings.value(PanelTabs.State.self, forKey: "left.tabs")?.tabs.count == 1)
    }

    /// Going to a folder that cannot be read leaves the panel where it was and tells the user.
    @Test
    internal func aFailedNavigationLeavesThePanelAndTellsTheUser() async {
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.commands.perform(.changeDirectory, .location(fixture.box.url("nowhere")))
        await app.settle()
        // The alert is raised after the code that found the error has returned.
        await AppWait.until(seconds: 2) { !fixture.user.log.isEmpty }
        #expect(
            app.left.model.directory.lastPathComponent == "A"
                && fixture.user.log == ["inform: The folder cannot be read!"]
        )
    }

    /// A file another program makes appears in the panel that shows its folder, and only there.
    @Test
    internal func changesMadeByOtherProgramsAppearByThemselves() async throws {
        let app = await fixture.startProgram()
        defer { app.stop() }
        try fixture.box.file("A/from-outside.txt", "x")
        #expect(await AppWait.until { app.names(app.left).contains("from-outside.txt") })
        // The other panel, which shows another folder, is left alone.
        #expect(app.names(app.right) == ["one.txt"])
    }

    /// A panel whose folder was removed goes to the parent folder when it is read again.
    @Test
    internal func aFolderThatVanishesIsLeftForItsParent() async throws {
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.commands.perform(.changeDirectory, .location(fixture.box.url("A/docs")))
        await app.settle()
        try FileManager.default.removeItem(at: fixture.box.url("A/docs"))
        app.commands.perform(.reread)
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "A" && app.names(app.left) == ["one.txt", "two.txt"])
    }
}
