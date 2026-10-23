import AFMContracts
import AFMKernel
import TestSupport
import Testing

/// Copying, moving, renaming, making and deleting through the commands, in the file system in memory.
extension PluginCommandTests {
    /// Copy asks for the target, then whether to overwrite the file that is there, and runs as a job.
    @Test
    internal func copyAsksForTheTargetAndAboutOverwriting() {
        left.moveCursor(toName: "one.txt")
        user.promptAnswers = [.accept]
        user.choiceAnswers = [0]
        commands.perform(.copy)
        #expect(user.log.contains("prompt: Copy \"one.txt\" to [mem:/B/one.txt]"))
        #expect(user.log.contains { $0.hasPrefix("choose: Overwrite:") })
        #expect(memory.contents("/B/one.txt") == "new")
        #expect(bench.jobService.titles == ["Copy:"] && !bench.jobService.reports.isEmpty)
    }

    /// Copying the selection copies folders with their contents, unmarks the source and shows the copies in the target.
    @Test
    internal func copyingASelectionDeselectsItAndRefreshesTheTarget() {
        commands.perform(.selectAll)
        user.promptAnswers = [.accept]
        user.choiceAnswers = [1]
        commands.perform(.copy)
        #expect(user.log.contains("prompt: Copy 3 file(s) to [mem:/B/*.*]"))
        #expect(memory.contents("/B/docs/in.txt") == "inside" && memory.exists("/B/two.txt"))
        #expect(left.model.selection.isEmpty && right.names == ["docs", "one.txt", "two.txt"])
        commands.perform(.restoreSelection)
        #expect(left.model.selection.count == 3)
    }

    /// Copying within the folder asks for the new name and puts the cursor on the copy.
    @Test
    internal func copyInTheSameFolderPutsTheCursorOnTheCopy() {
        left.moveCursor(toName: "two.txt")
        user.promptAnswers = [.text("two copy.txt")]
        commands.perform(.copySamePanel)
        #expect(user.log.contains("prompt: Copy \"two.txt\" to [two.txt]"))
        #expect(memory.contents("/A/two copy.txt") == "2" && left.model.cursorItem?.name == "two copy.txt")
    }

    /// Copying a file onto itself is refused with a message and changes nothing.
    @Test
    internal func copyingOntoItselfIsRefusedWithAMessage() {
        left.moveCursor(toName: "two.txt")
        user.promptAnswers = [.text("/A/")]
        commands.perform(.copy)
        #expect(user.log.last == "inform: You cannot copy a file to itself!")
        #expect(left.names == ["docs", "one.txt", "two.txt"])
    }

    /// Move takes a file to the other panel, rename renames in place, and a name that is taken is refused.
    @Test
    internal func moveAndRename() {
        left.moveCursor(toName: "two.txt")
        user.promptAnswers = [.accept]
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
        #expect(user.log.last == "inform: renamed.txt cannot be renamed!")
        #expect(memory.contents("/A/taken.txt") == "t" && memory.contents("/A/renamed.txt") == "new")
        #expect(left.model.cursorItem?.name == "renamed.txt")
    }

    /// New Folder makes nested folders and several at once, and says so when a folder cannot be made.
    @Test
    internal func newFolders() {
        left.moveCursor(toName: "docs")
        user.promptAnswers = [.text("made/inner | other")]
        commands.perform(.makeDirectory)
        #expect(user.log.contains("prompt: New folder (directory) [docs]"))
        #expect(memory.exists("/A/made/inner") && memory.exists("/A/other") && left.model.cursorItem?.name == "other")
        user.promptAnswers = [.text("docs")]
        commands.perform(.makeDirectory)
        #expect(user.log.last == "inform: The folder docs cannot be created!")
    }

    /// Delete asks twice for a full folder and deletes for good where there is no Trash; a no keeps the file.
    @Test
    internal func deleteAsksAndDeletesDirectlyWhereThereIsNoTrash() {
        left.moveCursor(toName: "docs")
        user.choiceAnswers = [0, 0]
        commands.perform(.delete)
        // This file system has no Trash, so F8 deletes for good and says so.
        #expect(
            user.log.contains("choose: Permanently delete / Do you really want to delete the selected directory docs?")
        )
        #expect(user.log.contains { $0.hasPrefix("choose: The directory mem:/A/docs is not empty!") })
        #expect(!memory.exists("/A/docs") && left.names == ["one.txt", "two.txt"])

        left.moveCursor(toName: "one.txt")
        user.choiceAnswers = [1]
        commands.perform(.deleteDirectly)
        #expect(memory.exists("/A/one.txt"))
    }

    /// On a file system that cannot be changed, every command that changes files is off and copying out is on.
    @Test
    internal func onAReadOnlyFileSystemChangingCommandsAreWithheld() {
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

    /// On the parent row the commands that work on a file are off, while New Folder and Open stay on.
    @Test
    internal func nothingIsOfferedOnTheParentRow() {
        left.model.moveCursor(to: 0)
        #expect(left.model.cursorIsOnParentRow)
        for command in [CommandID.copy, .renameMove, .renameOnly, .delete, .view, .edit, .cutToClipboard] {
            #expect(!commands.isEnabled(command), "\(command) should be disabled")
        }
        #expect(commands.isEnabled(.makeDirectory) && commands.isEnabled(.open))
    }
}
