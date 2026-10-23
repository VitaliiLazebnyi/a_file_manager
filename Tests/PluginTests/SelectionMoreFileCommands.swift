import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import SelectionPlugin

/// The Mark commands that save, load and compare, driven through a kernel with fake panels and an in-memory
/// file system.
@MainActor
@Suite
internal struct SelectionMoreFileCommands: SelectionMoreBench {
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

    /// Selections are saved to files and loaded from them, in both encodings and over a file.
    @Test
    internal func savingAndLoadingSelectionFiles() {
        let bench = makeBench()
        let (commands, left, interaction) = (bench.commands, bench.left, bench.interaction)
        commands.perform(.selectGroup, .text("docs *.md"))
        interaction.promptAnswers = [.text("sel")]
        commands.perform(Ids.saveSelectionToFile)
        #expect(bench.jobService.titles == ["Saving selection:"])
        let saved = data("/A/sel.txt")
        #expect(
            saved.starts(with: [0xFF, 0xFE])
                && Set(SelectionFile.text(from: saved).components(separatedBy: "\r\n")) == [
                    "docs\\", "two.md", "three.md"
                ]
        )
        // The panel shows the new file and keeps its selection.
        #expect(left.names.contains("sel.txt") && left.model.selection == ["docs", "two.md", "three.md"])

        commands.perform(Ids.saveSelection)
        commands.perform(.selectAll)
        interaction.promptAnswers = [.text("sel.txt")]
        commands.perform(Ids.loadSelectionFromFile)
        #expect(left.model.selection == ["docs", "two.md", "three.md"])
        commands.perform(.unselectAll)
        commands.perform(.restoreSelection)
        #expect(left.model.selection == ["docs", "two.md", "three.md"])

        // ANSI, to a full path, over an existing file only after a question.
        commands.perform(.unselectAll)
        left.moveCursor(toName: "one.txt")
        commands.perform(Ids.saveSelectionToFileANSI, .text("mem:/B/list.txt"))
        #expect(memory.contents("/B/list.txt") == "one.txt" && bench.right.names.contains("list.txt"))
        left.moveCursor(toName: "two.txt")
        commands.perform(Ids.saveSelectionToFileANSI, .location(memory.url("/B/list.txt")))
        #expect(
            memory.contents("/B/list.txt") == "one.txt"
                && interaction.log.last == "choose: mem:/B/list.txt already exists. / Do you want to overwrite it?"
        )
        interaction.choiceAnswers = [0]
        commands.perform(Ids.saveSelectionToFileUnicode, .location(memory.url("/B/list.txt")))
        #expect(SelectionFile.text(from: data("/B/list.txt")) == "two.txt")
        commands.perform(Ids.loadSelectionFromFile, .location(memory.url("/B/list.txt")))
        #expect(left.model.selection == ["two.txt"])

        commands.perform(Ids.loadSelectionFromFile, .text("missing.txt"))
        #expect(
            interaction.log.last == "inform: The selection cannot be loaded!" && left.model.selection == ["two.txt"]
        )
        interaction.promptAnswers = [.cancel]
        commands.perform(Ids.saveSelectionToFile)
        #expect(!memory.exists("/A/.txt"))
    }

    /// Selection files are written and read on the local disk too.
    @Test
    internal func selectionFilesOnTheLocalDisk() throws {
        let box = try Sandbox()
        try box.file("A/alpha.txt")
        try box.file("A/beta.txt")
        try box.folder("A/sub")
        try box.folder("B")
        let bench = makeBench()
        bench.left.show(box.url("A"))
        bench.commands.perform(.selectGroup, .text("alpha.* sub"))
        bench.commands.perform(Ids.saveSelectionToFile, .text("../B/chosen"))
        let written = try Data(contentsOf: box.url("B/chosen.txt"))
        #expect(SelectionFile.text(from: written) == "sub\\\r\nalpha.txt")
        bench.commands.perform(.invertSelection)
        #expect(bench.left.model.selection == ["beta.txt"])
        bench.commands.perform(Ids.loadSelectionFromFile, .text(box.url("B/chosen.txt").path))
        #expect(bench.left.model.selection == ["alpha.txt", "sub"])
    }

    /// The names on the clipboard become the selection.
    @Test
    internal func loadingFromTheClipboard() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        pasteboard.clearContents()
        commands.perform(Ids.loadSelectionFromClipboard)
        #expect(left.model.selection.isEmpty)
        pasteboard.setString("mem:/A/docs/\nmem:/A/one.txt\r\ntwo.md\nelsewhere.txt", forType: .string)
        commands.perform(.selectGroup, .text("big.bin"))
        commands.perform(Ids.loadSelectionFromClipboard)
        #expect(left.model.selection == ["docs", "one.txt", "two.md"])
    }

    /// Compare directories marks on both sides what differs, in each mode.
    @Test
    internal func comparingDirectories() {
        let bench = makeBench()
        let (commands, left, right) = (bench.commands, bench.left, bench.right)
        // The previous selection is replaced on both sides.
        right.model.selectAll()
        commands.perform(Ids.compareDirectories)
        #expect(
            left.model.selection == ["one.txt", "two.md", "big.bin", "three.md"]
                && right.model.selection == ["only_b.txt", "three.md"]
        )
        commands.perform(Ids.compareDirectories, .index(1))
        #expect(left.model.selection == ["two.md", "big.bin"] && right.model.selection == ["only_b.txt"])
        commands.perform(Ids.compareDirectories, .index(2))
        #expect(
            left.model.selection == ["two.md", "big.bin", "three.md"]
                && right.model.selection == ["only_b.txt", "three.md"]
        )
        commands.perform(Ids.compareDirectoriesWithSubdirectories, .index(1))
        #expect(
            left.model.selection == ["two.md", "big.bin", "docs"] && right.model.selection == ["only_b.txt", "extra"]
        )
        // Both panels on the same folder: nothing differs.
        right.show(memory.url("/A"))
        commands.perform(Ids.compareDirectories)
        #expect(left.model.selection.isEmpty && right.model.selection.isEmpty)
    }

    /// Mark newer, hide same files shows only what differs, until chosen again or the panel moves.
    @Test
    internal func markNewerHideSame() {
        let bench = makeBench()
        let (commands, left, right) = (bench.commands, bench.left, bench.right)
        commands.perform(Ids.markNewerHideSame)
        #expect(
            left.model.filter?.title == "Comparison: mem:/A/*.*"
                && right.model.filter?.title == "Comparison: mem:/B/*.*"
        )
        #expect(
            Set(left.names) == ["docs", "one.txt", "two.md", "three.md", "big.bin"]
                && Set(right.names) == ["extra", "one.txt", "three.md", "only_b.txt"]
        )
        // Same time but another size: shown, not marked.
        #expect(left.model.selection == ["one.txt", "two.md", "big.bin"] && right.model.selection == ["only_b.txt"])
        #expect(commands.isChecked(Ids.markNewerHideSame) && memory.exists("/A/two.txt"))
        // Choosing it again shows everything.
        commands.perform(Ids.markNewerHideSame)
        #expect(
            left.model.filter == nil && right.model.filter == nil && left.names.count == 7
                && !commands.isChecked(Ids.markNewerHideSame)
        )

        // The view ends when the panel goes elsewhere; the other panel keeps it.
        commands.perform(Ids.markNewerHideSame)
        left.show(memory.url("/A/docs"))
        bench.kernel.panelEvents.post(.locationChanged, from: left)
        #expect(left.model.filter == nil && left.names == ["in.txt"] && right.model.filter != nil)
        bench.kernel.panelEvents.post(.locationChanged, from: right)
        #expect(right.model.filter != nil)
    }
}
