import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Renaming and making new folders and files through the commands and their dialogs.
extension FileOperationCommands {
    // MARK: Rename

    /// Several items are renamed with one mask or one by one, and the single-file command ignores the selection.
    @Test
    internal func severalItemsAreRenamedWithAMaskOrOneByOne() {
        select("one.txt", "two.txt")
        interaction.formAnswers = [.values(["mask": .text("*.old")])]
        commands.perform(.renameOnly)
        #expect(
            interaction.log == ["form: Rename"] && memory.contents("/A/one.old") == "new"
                && memory.contents("/A/two.old") == "2"
        )
        #expect(left.names == ["docs", "notes.bak", "one.old", "two.old"] && left.model.selection.isEmpty)

        select("one.old", "two.old")
        interaction.formAnswers = [.values(["each": .flag(true)])]
        interaction.promptAnswers = [.text("first.txt"), .text("a*b.txt")]
        commands.perform(.renameOnly)
        #expect(interaction.log.contains("prompt: Rename \"two.old\" to [two.old]"))
        // A name typed for one file is taken as it is, stars and all.
        #expect(left.names == ["docs", "a*b.txt", "first.txt", "notes.bak"])

        // The single-file command ignores the selection.
        select("first.txt", "notes.bak")
        left.moveCursor(toName: "notes.bak")
        commands.perform("cm_RenameSingleFile", .text("notes.txt"))
        #expect(
            memory.exists("/A/notes.txt") && memory.exists("/A/first.txt") && left.model.cursorItem?.name == "notes.txt"
        )
    }

    // MARK: New folder and new file

    /// New folders take counter ranges, placeholders and paths, in this panel or the other one.
    @Test
    internal func newFoldersWithRangesPlaceholdersAndInTheOtherPanel() {
        left.moveCursor(toName: "docs")
        interaction.promptAnswers = [.text("<1-3>part[C]")]
        commands.perform(.makeDirectory)
        #expect(
            ["part1", "part2", "part3"].allSatisfy { memory.exists("/A/" + $0) }
                && left.model.cursorItem?.name == "part3"
        )
        // The optional digit takes the first free name; [N] is the name under the cursor.
        left.moveCursor(toName: "docs")
        interaction.promptAnswers = [.text("<docs[C]|Copy of [N]/[U]in")]
        commands.perform(.makeDirectory)
        #expect(memory.exists("/A/docs2") && memory.exists("/A/Copy of docs/IN"))
        let year = Calendar.current.component(.year, from: Date())
        interaction.promptAnswers = [.text("<[Y] archive")]
        commands.perform(.makeDirectory)
        #expect(memory.exists("/A/\(year) archive"))

        interaction.promptAnswers = [.text("there/deep")]
        commands.perform("cm_MkDirOther")
        #expect(memory.exists("/B/there/deep") && right.model.cursorItem?.name == "there" && !memory.exists("/A/there"))
        // With names as the argument nothing is asked.
        let asked = interaction.log.count
        commands.perform(.makeDirectory, .text("N=\"x|y/z\" G"))
        commands.perform(.makeDirectory, .text("plain"))
        #expect(
            interaction.log.count == asked && memory.exists("/A/x") && memory.exists("/A/y/z")
                && memory.exists("/A/plain")
        )
        interaction.promptAnswers = [.text("<[X]")]
        commands.perform(.makeDirectory, .text("<1-2>[Q"))
        #expect(memory.exists("/A/[Q"))
    }

    /// Several new files can be made at once, quoted or in a list; an existing file is left as it is.
    @Test
    internal func newFilesSeveralAtOnce() {
        interaction.promptAnswers = [.text("\"a 1.txt\" \"a 2.txt\"|sub/a3.txt")]
        commands.perform(.newTextFile)
        #expect(
            memory.contents("/A/a 1.txt")?.isEmpty == true && memory.contents("/A/a 2.txt")?.isEmpty == true
                && memory.contents("/A/sub/a3.txt")?.isEmpty == true
        )
        interaction.promptAnswers = [.text("<1-2>note[C:2].md")]
        commands.perform(.newTextFile, .text("1"))
        #expect(
            memory.exists("/A/note01.md") && memory.exists("/A/note02.md") && left.model.cursorItem?.name == "note02.md"
        )
        // An existing file is left as it is.
        interaction.promptAnswers = [.text("one.txt")]
        commands.perform(.newTextFile, .index(1))
        #expect(memory.contents("/A/one.txt") == "new")
    }
}
