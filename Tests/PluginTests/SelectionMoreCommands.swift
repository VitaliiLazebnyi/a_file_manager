import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import SelectionPlugin

/// The Mark commands that change a selection, driven through a kernel with fake panels and an in-memory file
/// system.
@MainActor
@Suite
internal struct SelectionMoreCommands: SelectionMoreBench {
    /// The file system the panels show.
    internal let memory = MemoryFileSystem()
    private let scratch = ScratchPasteboard()
    /// The clipboard the plugin reads.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The settings of the plugin.
    internal let settings = MemorySettings()

    /// Fills the folders the panels show.
    internal init() {
        Self.fill(memory)
    }

    /// The commands come with their keys, menu entries, toolbar buttons and options page.
    @Test
    internal func registration() {
        let bench = makeBench()
        let keys = bench.kernel.keyBindings
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(keys.command(for: .f(2, .shift)) == Ids.compareDirectories)
        #expect(keys.command(for: Shortcut(.keypadPlus, .option)) == Ids.selectCurrentExtension)
        #expect(keys.command(for: Shortcut(.keypadMinus, .option)) == Ids.unselectCurrentExtension)
        #expect(keys.command(for: Shortcut(.keypadMinus, .shift)) == Ids.clearFiles)
        #expect(keys.command(for: Shortcut(.keypadMultiply)) == .invertSelection && keys.command(for: .cmd("i")) == nil)
        let menus = bench.kernel.menus.menus
        #expect(menus.map(\.title) == ["Mark"])
        #expect(menus[0].items.compactMap(\.self).allSatisfy { bench.commands[$0] != nil })
        #expect(
            menus[0].items.contains(Ids.loadSelectionFromClipboard) && menus[0].items.contains(Ids.markNewerHideSame)
        )
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Selection"])
        let proposed = bench.kernel.toolbar.defaultLayout.compactMap(\.self).map(\.command)
        #expect(proposed == [.selectGroup, .unselectGroup, .invertSelection, Ids.compareDirectories])
    }

    /// Select group and Unselect group take masks, regular expressions and related files.
    @Test
    internal func groupsByMask() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        commands.perform(.selectGroup, .text("*.txt *.md | two.*"))
        #expect(left.model.selection == ["one.txt", "three.md"])
        commands.perform(.selectGroup, .text("<^(docs|big)"))
        #expect(left.model.selection == ["one.txt", "three.md", "docs", "big.bin"])
        commands.perform(.unselectGroup, .text("*.*|*.md"))
        #expect(left.model.selection == ["three.md"])
        commands.perform(Ids.selectFiles, .text("*.*"))
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md", "big.bin"])
        commands.perform(Ids.clearFiles, .text("two.*"))
        commands.perform(Ids.selectFolders, .text("s*"))
        #expect(left.model.selection == ["one.txt", "three.md", "big.bin", "shared"])
        commands.perform(.unselectAll)
        commands.perform(.selectGroup, .text("two.txt>*.md"))
        #expect(left.model.selection == ["two.txt", "two.md"])
        // The dialog proposes *.*, or the extension under the cursor.
        left.moveCursor(toName: "three.md")
        bench.interaction.promptAnswers = [.accept]
        commands.perform(Ids.selectGroupCurrentExtension)
        #expect(
            left.model.selection == ["two.txt", "two.md", "three.md"]
                && bench.interaction.log.last == "prompt: Expand selection [*.md]"
        )
        bench.interaction.promptAnswers = [.cancel]
        commands.perform(Ids.clearFolders)
        #expect(left.model.selection.count == 3)
        commands.perform(.selectGroup, .text("<("))
        #expect(
            bench.interaction.log.last == "inform: The regular expression cannot be read."
                && left.model.selection.count == 3
        )
    }

    /// Num + and its Shift variant take files or files and folders as configured.
    @Test
    internal func foldersAsConfigured() {
        settings.set(false, forKey: "selection.markDirectories")
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        commands.perform(.selectAll)
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md", "big.bin"])
        commands.perform(Ids.selectAllOtherChoice)
        #expect(left.model.selection.count == 7)
        commands.perform(.invertSelection)
        #expect(left.model.selection == ["docs", "shared"])
        commands.perform(Ids.invertOtherChoice)
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md", "big.bin"])
        commands.perform(Ids.invertFolders)
        commands.perform(Ids.clearAllFiles)
        #expect(left.model.selection == ["docs", "shared"])
        commands.perform(.selectGroup, .text("*"))
        commands.perform(Ids.clearAllFolders)
        #expect(left.model.selection.count == 5)
        commands.perform(Ids.selectGroupOtherChoice, .text("d*"))
        #expect(left.model.selection.contains("docs"))
        commands.perform(.unselectAll)
        #expect(left.model.selection.isEmpty)
        commands.perform(Ids.selectAllFolders)
        commands.perform(Ids.selectAllBoth)
        #expect(left.model.selection.count == 7)
    }

    /// Select all takes every n-th line, and Select and go to next moves past what it marks.
    @Test
    internal func everyNthLineAndSteps() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        let files = left.names.filter { !["docs", "shared"].contains($0) }
        left.moveCursor(toName: files[1])
        commands.perform(Ids.selectAllFiles, .index(2))
        #expect(left.model.selection == [files[1], files[3]])
        commands.perform(Ids.clearAllFiles, .index(-1))
        #expect(left.model.selection == [files[3]])
        commands.perform(.unselectAll)

        left.moveCursor(toName: left.names[0])
        let start = left.model.cursor
        commands.perform(Ids.select, .index(3))
        #expect(left.model.selection == Set(left.names.prefix(3)) && left.model.cursor == start + 3)
        commands.perform(Ids.unselect, .index(-2))
        #expect(left.model.selection == Set(left.names.prefix(2)) && left.model.cursor == start + 1)
        commands.perform(Ids.select)
        #expect(left.model.selection == Set(left.names.prefix(2)) && left.model.cursor == start + 2)
    }

    /// The entries like the one under the cursor are selected and unselected.
    @Test
    internal func likeTheItemUnderTheCursor() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        left.moveCursor(toName: "two.md")
        commands.perform(Ids.selectCurrentExtension)
        #expect(left.model.selection == ["two.md", "three.md"])
        commands.perform(Ids.selectCurrentName)
        #expect(left.model.selection == ["two.md", "three.md", "two.txt"])
        commands.perform(Ids.unselectCurrentExtension)
        #expect(left.model.selection == ["two.txt"])
        commands.perform(Ids.unselectCurrentName)
        commands.perform(Ids.selectCurrentNameAndExtension)
        #expect(left.model.selection == ["two.md"])
        commands.perform(Ids.selectCurrentPath)
        #expect(left.model.selection.count == 7)
        commands.perform(Ids.unselectCurrentPath)
        #expect(left.model.selection.isEmpty)
        // A folder has no extension to go by.
        left.moveCursor(toName: "docs")
        commands.perform(Ids.selectCurrentExtension)
        #expect(left.model.selection.isEmpty)
        left.model.moveCursor(to: 0)
        #expect(left.model.cursorIsOnParentRow && !commands.isEnabled(Ids.selectCurrentExtension))
    }

    /// Masks are remembered, listed after the saved types, and used or removed from the list.
    @Test
    internal func maskHistoryAndTheList() {
        let bench = makeBench()
        let (commands, left, interaction) = (bench.commands, bench.left, bench.interaction)
        commands.perform(Ids.selectFromList)
        #expect(interaction.log.last == "inform: There are no saved selection types or earlier masks yet.")
        commands.perform(.selectGroup, .text("*.md"))
        commands.perform(.unselectGroup, .text("*.*"))
        commands.perform(.selectGroup, .text("*.md"))
        commands.perform(.unselectAll)

        // Define a type: files of at least 1k.
        interaction.formAnswers = [
            .values(["name": .text("large"), "mask": .text("*.*"), "kind": .index(1), "minSize": .text("1k")])
        ]
        commands.perform(Ids.defineSelectionType)
        commands.perform(.selectGroup, .text(">Large"))
        #expect(left.model.selection == ["big.bin"])
        commands.perform(.selectGroup, .text(">nothing"))
        #expect(interaction.log.last == "inform: There is no selection type called nothing.")

        // The list holds the types first, then the masks, newest first.
        interaction.formAnswers = [.values(["row": .index(1)], button: 0)]
        commands.perform(Ids.selectFromList)
        if case .list(let rows, _)? = interaction.forms.last?.first?.kind {
            #expect(rows == [">large", "*.md", "*.*"])
        } else {
            Issue.record("no list")
        }
        #expect(left.model.selection == ["big.bin", "two.md", "three.md"])
        interaction.formAnswers = [.values(["row": .index(0)], button: 1)]
        commands.perform(Ids.selectFromList)
        #expect(left.model.selection == ["two.md", "three.md"])
        interaction.formAnswers = [.values(["row": .index(2)], button: 2)]
        commands.perform(Ids.selectFromList)

        // A second plugin instance reads the same settings: types and history persist.
        let again = makeBench()
        again.interaction.formAnswers = [.cancel]
        again.commands.perform(Ids.selectFromList)
        if case .list(let rows, _)? = again.interaction.forms.last?.first?.kind {
            #expect(rows == [">large", "*.md"])
        } else {
            Issue.record("no list")
        }
    }

    /// A selection type is defined, refused with a field that cannot be read, and deleted.
    @Test
    internal func definingAndEditingSelectionTypes() {
        let bench = makeBench()
        let (commands, left, interaction) = (bench.commands, bench.left, bench.interaction)
        interaction.formAnswers = [
            .values(["name": .text("large"), "mask": .text("*.*"), "kind": .index(1), "minSize": .text("1k")])
        ]
        commands.perform(Ids.defineSelectionType)
        // Editing: the type is picked, changed and refused when a field cannot be read.
        interaction.formAnswers = [
            .values(["row": .index(0)]), .values(["name": .text("small"), "maxSize": .text("lots")])
        ]
        commands.perform(Ids.defineSelectionType)
        #expect(interaction.log.last == "inform: The selection type was not saved.")
        interaction.formAnswers = [
            .values(["row": .index(0)]),
            .values(["name": .text("small"), "maxSize": .text("3"), "from": .text("1970-01-02")])
        ]
        commands.perform(Ids.defineSelectionType)
        commands.perform(.unselectAll)
        commands.perform(.selectGroup, .text(">small"))
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md"])
        interaction.formAnswers = [.values(["row": .index(2)]), .values([:], button: 1)]
        commands.perform(Ids.defineSelectionType)
        commands.perform(.selectGroup, .text(">small"))
        #expect(interaction.log.last == "inform: There is no selection type called small.")
    }

    /// A large list is selected with few announcements of the change.
    @Test
    internal func aLargeListIsSelectedWithFewAnnouncements() {
        for index in 0..<3_000 { memory.addFile("/big/file\(index).\(index.isMultiple(of: 2) ? "txt" : "md")") }
        let bench = makeBench()
        bench.left.show(memory.url("/big"))
        var announcements = 0
        bench.left.model.onChange = { _ in announcements += 1 }
        bench.commands.perform(.selectGroup, .text("*.txt"))
        #expect(bench.left.model.selection.count == 1_500 && announcements <= 2)
        announcements = 0
        bench.commands.perform(.unselectGroup, .text("file1*"))
        #expect(bench.left.model.selection.count == 1_500 - 555 && announcements == 1)
    }
}
