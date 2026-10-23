import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// Printing file lists and file contents, and what the plugin registers.
extension SystemToolsCommandTests {
    // MARK: Printing

    /// The file list goes to the printer in pages, and the dialog remembers what was entered.
    @Test
    internal func theFileListGoesToThePrinterAsPages() {
        bench.left.show(memory.url("/A"))
        commands.perform(.selectAll)
        interaction.formAnswers = [.values(["lines": .text("5"), "header": .text("")])]
        commands.perform(SystemToolsCommands.printList)
        // Three rows, an empty line and the totals on pages of five lines.
        #expect(tools.log == ["print: 1 pages"] && interaction.log.last == "form: Print directory")
        // The dialog remembers what was entered.
        interaction.formAnswers = [.cancel]
        commands.perform(SystemToolsCommands.printList)
        #expect(
            interaction.forms.last?.first?.initialValue == .text("")
                && interaction.forms.last?[2].initialValue == .text("5")
        )
    }

    /// The file list can be shown as text; Brief view prints the names only.
    @Test
    internal func theFileListCanBeShownAsText() {
        bench.left.show(memory.url("/A"))
        bench.left.moveCursor(toName: "one.txt")
        interaction.formAnswers = [.values(["output": .index(2)]), .accept]
        commands.perform(SystemToolsCommands.printList)
        let date = Format.date(Date(timeIntervalSince1970: 1_000_000))
        #expect(shownText() == "mem:/A - Page 1/1\n\none.txt  3  \(date)  rw-r--r--\n\n0 k in 1 files")
        // Brief view prints the names only; on `[..]` the whole list is meant.
        bench.left.viewMode = .brief
        bench.left.model.moveCursor(to: 0)
        interaction.formAnswers = [.accept, .accept]
        commands.perform(SystemToolsCommands.printList)
        #expect(shownText() == "mem:/A - Page 1/1\n\ndocs/\none.txt\ntwo.txt\n\n2 k in 2 files, 1 folders")
    }

    /// The list with subfolders asks for the depth and the mask, and asks before replacing a file.
    @Test
    internal func theListWithSubfoldersAsksForDepthAndMask() {
        bench.left.show(memory.url("/A"))
        commands.perform(.selectAll)
        interaction.promptAnswers = [.text("-1"), .text("*.txt | two.*"), .text("list.txt")]
        interaction.formAnswers = [.values(["output": .index(1), "details": .flag(false), "header": .text("%d")])]
        commands.perform(SystemToolsCommands.printListWithSubfolders)
        #expect(
            memory.contents("/A/list.txt")
                == "mem:/A\n\ndocs/\ndocs/deep/\ndocs/deep/far.txt\ndocs/in.txt\none.txt\n\n0 k in 3 files, 2 folders"
        )
        #expect(bench.left.model.cursorItem?.name == "list.txt" && tools.log == ["list-file: mem:/A/list.txt"])

        // Depth 1 enters the selected folders but not their subfolders; an existing file is asked about.
        commands.perform(.unselectAll)
        bench.left.moveCursor(toName: "docs")
        interaction.promptAnswers = [.text("1"), .accept, .text("list.txt")]
        interaction.formAnswers = [.values(["details": .flag(false)])]
        interaction.choiceAnswers = [0]
        commands.perform(SystemToolsCommands.printListWithSubfolders)
        #expect(
            memory.contents("/A/list.txt") == "mem:/A\n\ndocs/\ndocs/deep/\ndocs/in.txt\n\n0 k in 1 files, 2 folders"
        )
        interaction.promptAnswers = [.text("many")]
        commands.perform(SystemToolsCommands.printListWithSubfolders)
        #expect(interaction.log.last == "inform: many is not a number.")
    }

    /// Printing the contents of files is confirmed first, and needs a file among the operands.
    @Test
    internal func printingFileContentsIsConfirmedFirst() {
        bench.left.moveCursor(toName: "one.txt")
        interaction.choiceAnswers = [1, 0]
        commands.perform(SystemToolsCommands.printFile)
        #expect(tools.log.isEmpty)
        commands.perform(SystemToolsCommands.printFile)
        #expect(tools.log == ["print-file: one.txt"])
        bench.left.model.moveCursor(to: 0)
        #expect(!commands.isEnabled(SystemToolsCommands.printFile))
    }

    // MARK: Registration

    /// The commands are registered with their menus, toolbar buttons, keys and preferences.
    @Test
    internal func registration() {
        let menus = bench.kernel.menus
        let inMenus =
            menus.menus.flatMap(\.items).compactMap(\.self) + menus.contextMenu(onItem: true).compactMap(\.self)
        #expect(
            inMenus.allSatisfy { commands[$0] != nil }
                && Set(menus.menus.flatMap(\.items).compactMap(\.self)).count
                    == menus.menus.flatMap(\.items).compactMap(\.self).count
        )
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(
            menus.menus.first { $0.title == "Commands" }?.items
                == [
                    SystemToolsCommands.systemInformation, SystemToolsCommands.renameVolume,
                    SystemToolsCommands.ejectVolume,
                    SystemToolsCommands.openTerminal, nil, SystemToolsCommands.runPrompt
                ]
        )
        let buttons = bench.kernel.toolbar.defaultLayout.compactMap { $0?.command }
        #expect(
            buttons.filter { [SystemToolsCommands.openTerminal, SystemToolsCommands.systemInformation].contains($0) }
                == [SystemToolsCommands.openTerminal, SystemToolsCommands.systemInformation]
        )
        #expect(bench.kernel.preferences.pages.map(\.title).contains("System Tools"))
        #expect(
            bench.kernel.keyBindings.command(for: .f(9, .control)) == SystemToolsCommands.printFile
                && bench.kernel.keyBindings.command(for: .f(4, .option)) == SystemToolsCommands.quit
        )
        for id in [
            "afm_RunCommandLine", "cm_ExecuteDOS", "cm_SysInfo", "cm_VolumeId", "cm_PrintDir", "cm_PrintDirSub",
            "cm_PrintFile",
            "cm_Associate", "cm_Exit", "cm_Minimize"
        ] {
            #expect(commands[CommandID(rawValue: id)] != nil, "\(id)")
        }
    }
}
