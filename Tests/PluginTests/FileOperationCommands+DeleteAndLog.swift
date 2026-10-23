import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

/// Deleting through the commands and their questions, and the operation log they write.
extension FileOperationCommands {
    // MARK: Delete

    /// Deleting a read-only file asks once more, unless that question is switched off.
    @Test
    internal func readOnlyFilesAreAskedAboutAgainWhenDeleting() {
        memory.addFile("/A/ro.txt", "r", permissions: 0o444)
        left.reload()
        left.moveCursor(toName: "ro.txt")
        interaction.choiceAnswers = [0, 2]
        commands.perform(.delete)
        #expect(
            interaction.log.contains("choose: Delete: mem:/A/ro.txt is READ ONLY! / Delete anyway?")
                && memory.exists("/A/ro.txt")
        )
        interaction.choiceAnswers = [0, 0]
        commands.perform(.delete)
        #expect(!memory.exists("/A/ro.txt"))
        // The question can be switched off.
        memory.addFile("/A/ro.txt", "r", permissions: 0o444)
        left.reload()
        left.moveCursor(toName: "ro.txt")
        settings.set(false, forKey: "fileOperations.askReadOnly")
        interaction.choiceAnswers = [0]
        commands.perform(.delete)
        #expect(!memory.exists("/A/ro.txt"))
    }

    /// With the trash switched off F8 deletes for good and the other delete key moves to the trash.
    @Test
    internal func theTrashKeyCanBeTurnedAround() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        left.show(box.url("A"))
        right.show(box.url("B"))
        left.moveCursor(toName: "readme.md")
        settings.set(false, forKey: "fileOperations.useTrash")
        interaction.choiceAnswers = [1, 1]
        commands.perform(.delete)
        #expect(
            interaction.log.last
                == "choose: Permanently delete / Do you really want to delete the selected file readme.md?"
        )
        commands.perform(.deleteDirectly)
        #expect(
            interaction.log.last
                == "choose: Test / Do you really want to move the selected file readme.md to the Trash?"
        )
        #expect(box.exists("A/readme.md"))
        // Non-empty folders can go without the extra question.
        try box.file("A/full/in.txt")
        left.reload()
        left.moveCursor(toName: "full")
        settings.set(false, forKey: "fileOperations.askNonEmptyFolders")
        interaction.choiceAnswers = [0]
        commands.perform(.delete)
        #expect(!box.exists("A/full") && !interaction.log.contains { $0.contains("is not empty") })
    }

    // MARK: Log

    /// Copies, new folders, renames and deletes are written to the log file when it is on.
    @Test
    internal func operationsAreWrittenToTheLogFile() throws {
        let box = try Sandbox()
        settings.set(true, forKey: "fileOperations.log.enabled")
        settings.set(box.url("log/ops.log").path, forKey: "fileOperations.log.file")
        left.moveCursor(toName: "two.txt")
        interaction.promptAnswers = [.accept, .text("made")]
        commands.perform(.copy)
        commands.perform(.makeDirectory)
        left.moveCursor(toName: "two.txt")
        commands.perform(.renameOnly, .text("zwei.txt"))
        left.moveCursor(toName: "made")
        interaction.choiceAnswers = [0]
        commands.perform(.delete)
        // The log writes on its own queue.
        var text = ""
        for _ in 0..<200 where text.components(separatedBy: "\n").count < 5 {
            Thread.sleep(forTimeInterval: 0.01)
            text = box.read("log/ops.log") ?? ""
        }
        let lines = text.split(separator: "\n").map { String($0.dropFirst(21)) }
        #expect(
            lines == [
                "Copy: mem:/A/two.txt -> mem:/B/two.txt", "New folder: mem:/A/made",
                "Rename: mem:/A/two.txt -> mem:/A/zwei.txt",
                "Delete folder: mem:/A/made"
            ]
        )
    }
}
