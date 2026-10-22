import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

/// The file-operation commands with their dialogs, driven through a kernel with fake panels.
@MainActor
@Suite
internal struct FileOperationCommands {
    internal let memory = MemoryFileSystem()
    internal let settings = MemorySettings()
    internal let bench: TestBench

    internal var commands: CommandRegistry { bench.commands }
    internal var left: FakePanel { bench.left }
    internal var right: FakePanel { bench.right }
    internal var ui: ScriptedInteraction { bench.interaction }

    internal init() {
        memory.addFile("/A/one.txt", "new")
        memory.addFile("/A/two.txt", "2")
        memory.addFile("/A/notes.bak", "b")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/B/one.txt", "old")
        bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    internal func select(_ names: String...) {
        for name in names {
            left.moveCursor(toName: name)
            left.model.toggleSelection(row: left.model.cursor)
        }
    }

    // MARK: Registration

    @Test
    internal func commandsKeysPagesAndButtons() {
        let expected: [(CommandID, [Shortcut])] = [
            ("cm_Copy", [.f(5)]), ("cm_CopySamepanel", [.f(5, .shift)]), ("cm_CopyOtherpanel", []),
            ("cm_RenMov", [.f(6)]), ("cm_MoveOnly", []),
            ("cm_RenameOnly", [.f(6, .shift)]), ("cm_RenameSingleFile", []), ("cm_MkDir", [.f(7)]),
            ("cm_MkDirOther", [.f(7, .shift)]),
            ("cm_EditNewFile", [.f(4, .shift)]), ("afm_CopyWithOptions", []), ("afm_MoveWithOptions", []),
            ("afm_CopyNoAsk", []), ("afm_MoveNoAsk", [])
        ]
        for (id, shortcuts) in expected {
            #expect(commands[id]?.defaultShortcuts == shortcuts, "\(id)")
        }
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Copy/Delete", "Log file"])
        #expect(
            bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [
                .copy, .renameMove, .makeDirectory, .delete
            ]
        )
        #expect(bench.kernel.menus.contextMenu(onItem: true).contains(.copy))
    }

    // MARK: Copy and move

    @Test
    internal func theOptionsDialogCarriesFilterAndOverwriteMode() {
        left.model.selectAll()
        ui.formAnswers = [
            .values(["filter": .text("*.txt | docs/"), "overwrite": .index(OverwriteMode.skipAll.rawValue)])
        ]
        commands.perform("afm_CopyWithOptions")
        #expect(ui.log.contains("form: Copy"))
        let keys = ui.forms[0].map(\.key)
        #expect(
            keys.contains("target") && keys.contains("verify") && keys.contains("links") && keys.contains("skipErrors")
        )
        // Nothing was asked: the preset skipped one.txt; the filter left docs and the .bak file out.
        #expect(!ui.log.contains { $0.hasPrefix("choose:") })
        #expect(memory.contents("/B/one.txt") == "old" && memory.contents("/B/two.txt") == "2")
        #expect(!memory.exists("/B/docs") && !memory.exists("/B/notes.bak"))
        // What the filter left out stays selected (07 › Only files of this type).
        #expect(left.model.selection == ["docs", "notes.bak", "one.txt"])
    }

    @Test
    internal func theOptionsCanBecomeTheDefaultsAndAlwaysBeShown() {
        left.moveCursor(toName: "two.txt")
        ui.formAnswers = [.values(["verify": .flag(true), "overwrite": .index(1)], button: 1)]
        commands.perform("afm_MoveWithOptions")
        #expect(ui.log.contains("form: Rename/Move") && !ui.forms[0].map(\.key).contains("links"))
        #expect(memory.exists("/B/two.txt") && !memory.exists("/A/two.txt"))
        #expect(
            settings.flag("fileOperations.verify", default: false)
                && settings.index("fileOperations.overwriteMode", default: 0) == 1
        )

        // The stored defaults hold for the plain F5 too: one.txt is overwritten without a question.
        left.moveCursor(toName: "one.txt")
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(memory.contents("/B/one.txt") == "new" && !ui.log.contains { $0.hasPrefix("choose:") })

        settings.set(true, forKey: "fileOperations.alwaysShowOptions")
        ui.formAnswers = [.cancel]
        commands.perform(.copy)
        #expect(ui.log.last == "form: Copy")
    }

    @Test
    internal func commandSwitchesStartWithoutADialog() {
        left.model.selectAll()
        commands.perform(.copy, .text("/O2 G W=\"*.txt\" T=\"mem:/B/sub/\""))
        #expect(ui.log.isEmpty)
        #expect(
            memory.contents("/B/sub/one.txt") == "new" && memory.contents("/B/sub/docs/in.txt") == "inside"
                && !memory.exists("/B/sub/notes.bak")
        )
        // Without G the switches only fill the dialog.
        left.model.deselect(left.model.selection)
        left.moveCursor(toName: "two.txt")
        ui.promptAnswers = [.cancel]
        commands.perform(.renameMove, .text("T=\"mem:/B/*.old\""))
        #expect(ui.log == ["prompt: Rename/Move \"two.txt\" to [mem:/B/*.old]"])
    }

    @Test
    internal func copyAndMoveWithoutAsking() {
        left.moveCursor(toName: "two.txt")
        commands.perform("afm_CopyNoAsk")
        #expect(memory.contents("/B/two.txt") == "2" && memory.exists("/A/two.txt") && ui.log.isEmpty)
        left.moveCursor(toName: "notes.bak")
        commands.perform("afm_MoveNoAsk")
        #expect(memory.exists("/B/notes.bak") && !memory.exists("/A/notes.bak") && right.names.contains("notes.bak"))
        // A name that exists still gets its question.
        left.moveCursor(toName: "one.txt")
        ui.choiceAnswers = [2]
        commands.perform("cm_CopyOtherpanel", .text("G"))
        #expect(ui.log.contains { $0.hasPrefix("choose: Overwrite:") } && memory.contents("/B/one.txt") == "old")
    }

    @Test
    internal func theOverwriteDialogShowsBothFilesAndOffersEveryChoice() {
        left.moveCursor(toName: "one.txt")
        // Rename…: the new name is asked for.
        ui.promptAnswers = [.accept, .text("one copy.txt")]
        ui.choiceAnswers = [5]
        commands.perform(.copy)
        let question = ui.log.first { $0.hasPrefix("choose: Overwrite:") } ?? ""
        #expect(
            question.contains("mem:/B/one.txt\n3 bytes") && question.contains("With file:\nmem:/A/one.txt")
                && question.contains("The file being copied is of the same age and of the same size.")
        )
        #expect(ui.log.contains("prompt: New name for the file being copied: [one.txt]"))
        #expect(memory.contents("/B/one copy.txt") == "new" && memory.contents("/B/one.txt") == "old")

        // More… › Compare contents says what it found and comes back; then More… › Auto-rename target files.
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [6, 6]
        ui.formAnswers = [.values(["row": .index(0)]), .values(["row": .index(4)])]
        commands.perform(.copy)
        #expect(ui.log.contains("inform: The two files are different!"))
        #expect(memory.contents("/B/one (2).txt") == "old" && memory.contents("/B/one.txt") == "new")
        // The list behind More…: Append for a copy, no Resume for a target that is not shorter.
        guard case .list(let rows, _) = ui.forms[0][0].kind else {
            Issue.record("no list")
            return
        }
        #expect(rows.count == 9 && rows[1].hasPrefix("Append") && !rows.contains { $0.hasPrefix("Resume") })

        // More… › Append; a dismissed More… list returns to the question, whose last button cancels.
        ui.promptAnswers = [.accept, .accept]
        ui.choiceAnswers = [6, 6]
        ui.formAnswers = [.values(["row": .index(1)]), .cancel]
        commands.perform(.copy)
        #expect(memory.contents("/B/one.txt") == "newnew")
        commands.perform(.copy)
        #expect(memory.contents("/B/one.txt") == "newnew")
    }

    @Test
    internal func aShorterTargetCanBeResumedButAMoveCannotAppend() {
        memory.addFile("/B/two.txt", "")
        memory.addFile("/A/long.txt", "0123456789")
        memory.addFile("/B/long.txt", "0123")
        left.reload()
        left.moveCursor(toName: "long.txt")
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [6]
        ui.formAnswers = [.values(["row": .index(1)])]
        commands.perform(.renameMove)
        guard case .list(let rows, _) = ui.forms[0][0].kind else {
            Issue.record("no list")
            return
        }
        #expect(rows[1].hasPrefix("Resume") && !rows.contains { $0.hasPrefix("Append") })
        #expect(memory.contents("/B/long.txt") == "0123456789" && !memory.exists("/A/long.txt"))
    }

    @Test
    internal func keepingGoingOnErrorsReportsAtTheEnd() {
        settings.set(true, forKey: "fileOperations.keepGoingOnErrors")
        select("docs", "two.txt")
        memory.unreadable = ["/A/docs"]
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(ui.log.last == "inform: 1 item(s) could not be processed." && memory.exists("/B/two.txt"))
        #expect(left.model.selection == ["docs"])
    }

    // MARK: Rename

    @Test
    internal func severalItemsAreRenamedWithAMaskOrOneByOne() {
        select("one.txt", "two.txt")
        ui.formAnswers = [.values(["mask": .text("*.old")])]
        commands.perform(.renameOnly)
        #expect(
            ui.log == ["form: Rename"] && memory.contents("/A/one.old") == "new" && memory.contents("/A/two.old") == "2"
        )
        #expect(left.names == ["docs", "notes.bak", "one.old", "two.old"] && left.model.selection.isEmpty)

        select("one.old", "two.old")
        ui.formAnswers = [.values(["each": .flag(true)])]
        ui.promptAnswers = [.text("first.txt"), .text("a*b.txt")]
        commands.perform(.renameOnly)
        #expect(ui.log.contains("prompt: Rename \"two.old\" to [two.old]"))
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

    @Test
    internal func newFoldersWithRangesPlaceholdersAndInTheOtherPanel() {
        left.moveCursor(toName: "docs")
        ui.promptAnswers = [.text("<1-3>part[C]")]
        commands.perform(.makeDirectory)
        #expect(
            ["part1", "part2", "part3"].allSatisfy { memory.exists("/A/" + $0) }
                && left.model.cursorItem?.name == "part3"
        )
        // The optional digit takes the first free name; [N] is the name under the cursor.
        left.moveCursor(toName: "docs")
        ui.promptAnswers = [.text("<docs[C]|Copy of [N]/[U]in")]
        commands.perform(.makeDirectory)
        #expect(memory.exists("/A/docs2") && memory.exists("/A/Copy of docs/IN"))
        let year = Calendar.current.component(.year, from: Date())
        ui.promptAnswers = [.text("<[Y] archive")]
        commands.perform(.makeDirectory)
        #expect(memory.exists("/A/\(year) archive"))

        ui.promptAnswers = [.text("there/deep")]
        commands.perform("cm_MkDirOther")
        #expect(memory.exists("/B/there/deep") && right.model.cursorItem?.name == "there" && !memory.exists("/A/there"))
        // With names as the argument nothing is asked.
        let asked = ui.log.count
        commands.perform(.makeDirectory, .text("N=\"x|y/z\" G"))
        commands.perform(.makeDirectory, .text("plain"))
        #expect(ui.log.count == asked && memory.exists("/A/x") && memory.exists("/A/y/z") && memory.exists("/A/plain"))
        ui.promptAnswers = [.text("<[X]")]
        commands.perform(.makeDirectory, .text("<1-2>[Q"))
        #expect(memory.exists("/A/[Q"))
    }

    @Test
    internal func newFilesSeveralAtOnce() {
        ui.promptAnswers = [.text("\"a 1.txt\" \"a 2.txt\"|sub/a3.txt")]
        commands.perform(.newTextFile)
        #expect(
            memory.contents("/A/a 1.txt") == "" && memory.contents("/A/a 2.txt") == ""
                && memory.contents("/A/sub/a3.txt") == ""
        )
        ui.promptAnswers = [.text("<1-2>note[C:2].md")]
        commands.perform(.newTextFile, .text("1"))
        #expect(
            memory.exists("/A/note01.md") && memory.exists("/A/note02.md") && left.model.cursorItem?.name == "note02.md"
        )
        // An existing file is left as it is.
        ui.promptAnswers = [.text("one.txt")]
        commands.perform(.newTextFile, .index(1))
        #expect(memory.contents("/A/one.txt") == "new")
    }

    // MARK: Delete

    @Test
    internal func readOnlyFilesAreAskedAboutAgainWhenDeleting() {
        memory.addFile("/A/ro.txt", "r", permissions: 0o444)
        left.reload()
        left.moveCursor(toName: "ro.txt")
        ui.choiceAnswers = [0, 2]
        commands.perform(.delete)
        #expect(
            ui.log.contains("choose: Delete: mem:/A/ro.txt is READ ONLY! / Delete anyway?")
                && memory.exists("/A/ro.txt")
        )
        ui.choiceAnswers = [0, 0]
        commands.perform(.delete)
        #expect(!memory.exists("/A/ro.txt"))
        // The question can be switched off.
        memory.addFile("/A/ro.txt", "r", permissions: 0o444)
        left.reload()
        left.moveCursor(toName: "ro.txt")
        settings.set(false, forKey: "fileOperations.askReadOnly")
        ui.choiceAnswers = [0]
        commands.perform(.delete)
        #expect(!memory.exists("/A/ro.txt"))
    }

    @Test
    internal func theTrashKeyCanBeTurnedAround() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        left.show(box.url("A"))
        right.show(box.url("B"))
        left.moveCursor(toName: "readme.md")
        settings.set(false, forKey: "fileOperations.useTrash")
        ui.choiceAnswers = [1, 1]
        commands.perform(.delete)
        #expect(ui.log.last == "choose: Permanently delete / Do you really want to delete the selected file readme.md?")
        commands.perform(.deleteDirectly)
        #expect(ui.log.last == "choose: Test / Do you really want to move the selected file readme.md to the Trash?")
        #expect(box.exists("A/readme.md"))
        // Non-empty folders can go without the extra question.
        try box.file("A/full/in.txt")
        left.reload()
        left.moveCursor(toName: "full")
        settings.set(false, forKey: "fileOperations.askNonEmptyFolders")
        ui.choiceAnswers = [0]
        commands.perform(.delete)
        #expect(!box.exists("A/full") && !ui.log.contains { $0.contains("is not empty") })
    }

    // MARK: Log

    @Test
    internal func operationsAreWrittenToTheLogFile() throws {
        let box = try Sandbox()
        settings.set(true, forKey: "fileOperations.log.enabled")
        settings.set(box.url("log/ops.log").path, forKey: "fileOperations.log.file")
        left.moveCursor(toName: "two.txt")
        ui.promptAnswers = [.accept, .text("made")]
        commands.perform(.copy)
        commands.perform(.makeDirectory)
        left.moveCursor(toName: "two.txt")
        commands.perform(.renameOnly, .text("zwei.txt"))
        left.moveCursor(toName: "made")
        ui.choiceAnswers = [0]
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
