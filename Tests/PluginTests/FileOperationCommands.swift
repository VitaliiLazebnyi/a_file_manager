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
    /// The files the commands work on: folder A in the left panel, B in the right one.
    internal let memory = MemoryFileSystem()
    /// The settings the plugin reads, so a test can change them.
    internal let settings = MemorySettings()
    /// The kernel with the plugin and the two fake panels.
    internal let bench: TestBench

    /// The kernel's commands, to perform them by name.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, the source of the commands.
    internal var left: FakePanel { bench.left }
    /// The right panel, the usual target.
    internal var right: FakePanel { bench.right }
    /// The scripted dialogs: their answers and what they were asked.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// Folder A with two text files, a backup and a subfolder; folder B with an older `one.txt`.
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

    /// Marks the named items of the left panel.
    internal func select(_ names: String...) {
        for name in names {
            left.moveCursor(toName: name)
            left.model.toggleSelection(row: left.model.cursor)
        }
    }

    // MARK: Registration

    /// Every command has its default keys, and the plugin adds its settings pages, toolbar buttons and menu items.
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

    /// The options dialog hands its file filter and overwrite mode to the copy; what the filter left out stays marked.
    @Test
    internal func theOptionsDialogCarriesFilterAndOverwriteMode() {
        left.model.selectAll()
        interaction.formAnswers = [
            .values(["filter": .text("*.txt | docs/"), "overwrite": .index(OverwriteMode.skipAll.rawValue)])
        ]
        commands.perform("afm_CopyWithOptions")
        #expect(interaction.log.contains("form: Copy"))
        let keys = interaction.forms[0].map(\.key)
        #expect(
            keys.contains("target") && keys.contains("verify") && keys.contains("links") && keys.contains("skipErrors")
        )
        // Nothing was asked: the preset skipped one.txt; the filter left docs and the .bak file out.
        #expect(!interaction.log.contains { $0.hasPrefix("choose:") })
        #expect(memory.contents("/B/one.txt") == "old" && memory.contents("/B/two.txt") == "2")
        #expect(!memory.exists("/B/docs") && !memory.exists("/B/notes.bak"))
        // What the filter left out stays selected (07 › Only files of this type).
        #expect(left.model.selection == ["docs", "notes.bak", "one.txt"])
    }

    /// The options can be stored as the defaults, which then hold for a plain F5, and can be shown every time.
    @Test
    internal func theOptionsCanBecomeTheDefaultsAndAlwaysBeShown() {
        left.moveCursor(toName: "two.txt")
        interaction.formAnswers = [.values(["verify": .flag(true), "overwrite": .index(1)], button: 1)]
        commands.perform("afm_MoveWithOptions")
        #expect(interaction.log.contains("form: Rename/Move") && !interaction.forms[0].map(\.key).contains("links"))
        #expect(memory.exists("/B/two.txt") && !memory.exists("/A/two.txt"))
        #expect(
            settings.flag("fileOperations.verify", default: false)
                && settings.index("fileOperations.overwriteMode", default: 0) == 1
        )

        // The stored defaults hold for the plain F5 too: one.txt is overwritten without a question.
        left.moveCursor(toName: "one.txt")
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(memory.contents("/B/one.txt") == "new" && !interaction.log.contains { $0.hasPrefix("choose:") })

        settings.set(true, forKey: "fileOperations.alwaysShowOptions")
        interaction.formAnswers = [.cancel]
        commands.perform(.copy)
        #expect(interaction.log.last == "form: Copy")
    }

    /// Command switches with G start the copy at once; without G they only fill in the dialog.
    @Test
    internal func commandSwitchesStartWithoutADialog() {
        left.model.selectAll()
        commands.perform(.copy, .text("/O2 G W=\"*.txt\" T=\"mem:/B/sub/\""))
        #expect(interaction.log.isEmpty)
        #expect(
            memory.contents("/B/sub/one.txt") == "new" && memory.contents("/B/sub/docs/in.txt") == "inside"
                && !memory.exists("/B/sub/notes.bak")
        )
        // Without G the switches only fill the dialog.
        left.model.deselect(left.model.selection)
        left.moveCursor(toName: "two.txt")
        interaction.promptAnswers = [.cancel]
        commands.perform(.renameMove, .text("T=\"mem:/B/*.old\""))
        #expect(interaction.log == ["prompt: Rename/Move \"two.txt\" to [mem:/B/*.old]"])
    }

    /// The no-ask commands copy and move at once, yet a name that exists still gets its question.
    @Test
    internal func copyAndMoveWithoutAsking() {
        left.moveCursor(toName: "two.txt")
        commands.perform("afm_CopyNoAsk")
        #expect(memory.contents("/B/two.txt") == "2" && memory.exists("/A/two.txt") && interaction.log.isEmpty)
        left.moveCursor(toName: "notes.bak")
        commands.perform("afm_MoveNoAsk")
        #expect(memory.exists("/B/notes.bak") && !memory.exists("/A/notes.bak") && right.names.contains("notes.bak"))
        // A name that exists still gets its question.
        left.moveCursor(toName: "one.txt")
        interaction.choiceAnswers = [2]
        commands.perform("cm_CopyOtherpanel", .text("G"))
        #expect(
            interaction.log.contains { $0.hasPrefix("choose: Overwrite:") } && memory.contents("/B/one.txt") == "old"
        )
    }

    /// The overwrite question shows both files and offers rename, compare, auto-rename and append.
    @Test
    internal func theOverwriteDialogShowsBothFilesAndOffersEveryChoice() {
        left.moveCursor(toName: "one.txt")
        // Rename…: the new name is asked for.
        interaction.promptAnswers = [.accept, .text("one copy.txt")]
        interaction.choiceAnswers = [5]
        commands.perform(.copy)
        let question = interaction.log.first { $0.hasPrefix("choose: Overwrite:") } ?? ""
        #expect(
            question.contains("mem:/B/one.txt\n3 bytes") && question.contains("With file:\nmem:/A/one.txt")
                && question.contains("The file being copied is of the same age and of the same size.")
        )
        #expect(interaction.log.contains("prompt: New name for the file being copied: [one.txt]"))
        #expect(memory.contents("/B/one copy.txt") == "new" && memory.contents("/B/one.txt") == "old")

        // More… › Compare contents says what it found and comes back; then More… › Auto-rename target files.
        interaction.promptAnswers = [.accept]
        interaction.choiceAnswers = [6, 6]
        interaction.formAnswers = [.values(["row": .index(0)]), .values(["row": .index(4)])]
        commands.perform(.copy)
        #expect(interaction.log.contains("inform: The two files are different!"))
        #expect(memory.contents("/B/one (2).txt") == "old" && memory.contents("/B/one.txt") == "new")
        // The list behind More…: Append for a copy, no Resume for a target that is not shorter.
        guard case .list(let rows, _) = interaction.forms[0][0].kind else {
            Issue.record("no list")
            return
        }
        #expect(rows.count == 9 && rows[1].hasPrefix("Append") && !rows.contains { $0.hasPrefix("Resume") })

        // More… › Append; a dismissed More… list returns to the question, whose last button cancels.
        interaction.promptAnswers = [.accept, .accept]
        interaction.choiceAnswers = [6, 6]
        interaction.formAnswers = [.values(["row": .index(1)]), .cancel]
        commands.perform(.copy)
        #expect(memory.contents("/B/one.txt") == "newnew")
        commands.perform(.copy)
        #expect(memory.contents("/B/one.txt") == "newnew")
    }

    /// A shorter target can be resumed, and a move is not offered to append.
    @Test
    internal func aShorterTargetCanBeResumedButAMoveCannotAppend() {
        memory.addFile("/B/two.txt", "")
        memory.addFile("/A/long.txt", "0123456789")
        memory.addFile("/B/long.txt", "0123")
        left.reload()
        left.moveCursor(toName: "long.txt")
        interaction.promptAnswers = [.accept]
        interaction.choiceAnswers = [6]
        interaction.formAnswers = [.values(["row": .index(1)])]
        commands.perform(.renameMove)
        guard case .list(let rows, _) = interaction.forms[0][0].kind else {
            Issue.record("no list")
            return
        }
        #expect(rows[1].hasPrefix("Resume") && !rows.contains { $0.hasPrefix("Append") })
        #expect(memory.contents("/B/long.txt") == "0123456789" && !memory.exists("/A/long.txt"))
    }

    /// With keep going on errors the job finishes the rest and reports the failures at the end.
    @Test
    internal func keepingGoingOnErrorsReportsAtTheEnd() {
        settings.set(true, forKey: "fileOperations.keepGoingOnErrors")
        select("docs", "two.txt")
        memory.unreadable = ["/A/docs"]
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(interaction.log.last == "inform: 1 item(s) could not be processed." && memory.exists("/B/two.txt"))
        #expect(left.model.selection == ["docs"])
    }
}
