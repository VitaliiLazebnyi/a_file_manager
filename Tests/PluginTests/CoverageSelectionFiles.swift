import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import SelectionPlugin

/// Selection files and the clipboard beyond the other suites: writes that fail or are
/// cancelled, a file system that cannot replace in one step, and lists of names that match
/// nothing or only read alike.
@MainActor
@Suite
internal struct CoverageSelectionFiles {
    /// The commands of this plugin.
    private typealias Ids = SelectionCommands

    /// The files: `/A` with a folder and two files, `/B` empty.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The clipboard the plugin reads.
    private let scratch = ScratchPasteboard()

    /// The files.
    internal init() {
        memory.addFile("/A/docs/in.txt")
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/Café.txt", "2")
        memory.addDirectory("/B")
        files = CoverageSmallFiles(memory)
    }

    /// A kernel with the plugin, its jobs run at once.
    private func immediateBench() -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: scratch.pasteboard, background: false)],
            fileSystems: [files],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// A kernel with the plugin, its jobs run as `jobs` says.
    private func bench(_ jobs: CoverageSmallJobs.Mode) -> CoverageSmallBench {
        CoverageSmallBench(
            jobs,
            plugins: [SelectionPlugin(pasteboard: scratch.pasteboard, background: false)],
            fileSystems: [files],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// A failed write is reported and leaves nothing; a move that fails without replacing is
    /// reported too.
    @Test
    internal func failedWritesAreReported() {
        let bench = immediateBench()
        bench.left.moveCursor(toName: "one.txt")
        files.fails = [.write]
        bench.commands.perform(Ids.saveSelectionToFile, .text("list"))
        files.fails = [.move]
        bench.commands.perform(Ids.saveSelectionToFile, .text("list"))
        #expect(bench.interaction.log == Array(repeating: "inform: The selection cannot be saved!", count: 2))
        #expect(!memory.allPaths.contains { $0.hasPrefix("/A/.list") || $0 == "/A/list.txt" })
    }

    /// Where a file cannot be replaced in one step, the old one goes and the new one moves in.
    @Test
    internal func aFileThatCannotBeReplacedInOneStepIsRemovedFirst() {
        let bench = immediateBench()
        memory.addFile("/A/list.txt", "old")
        bench.left.reload()
        bench.left.moveCursor(toName: "one.txt")
        files.fail(.move, times: 1)
        bench.interaction.choiceAnswers = [0]
        bench.commands.perform(Ids.saveSelectionToFileANSI, .text("list.txt"))
        #expect(memory.contents("/A/list.txt") == "one.txt" && bench.interaction.log.count == 1)
    }

    /// A save or a load whose job is cancelled ends quietly and leaves nothing.
    @Test
    internal func cancelledJobsEndQuietly() {
        let bench = bench(.cancelled)
        memory.addFile("/A/names.txt", "one.txt")
        bench.left.reload()
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(Ids.saveSelectionToFile, .text("list"))
        bench.commands.perform(Ids.loadSelectionFromFile, .text("names.txt"))
        #expect(bench.jobService.titles == ["Saving selection:", "Loading selection:"])
        #expect(bench.interaction.log.isEmpty && bench.left.model.selection.isEmpty && !memory.exists("/A/list.txt"))
    }

    /// A save cancelled once the file is written removes it again.
    @Test
    internal func aSaveCancelledAfterWritingRemovesTheFile() async {
        let bench = bench(.background)
        let jobs = bench.jobService
        files.onCall = { call in
            if call == .close { jobs.cancelAll() }
        }
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(Ids.saveSelectionToFile, .text("list"))
        #expect(await jobs.settle { jobs.running == 0 })
        #expect(bench.interaction.log.isEmpty && !memory.allPaths.contains { $0.contains("list") })
    }

    /// Names that arrive when the panel shows another folder are not selected there.
    @Test
    internal func namesThatArriveElsewhereAreNotSelected() async {
        let bench = bench(.background)
        memory.addFile("/A/names.txt", "one.txt")
        memory.addFile("/B/one.txt", "1")
        bench.left.reload()
        bench.commands.perform(Ids.loadSelectionFromFile, .text("names.txt"))
        bench.left.show(memory.url("/B"))
        #expect(await bench.jobService.settle { bench.jobService.running == 0 })
        #expect(bench.left.model.selection.isEmpty && bench.interaction.log.isEmpty)
    }

    /// Loading proposes nothing on a folder, and a cancelled prompt loads nothing.
    @Test
    internal func loadingFromAFolderProposesNothing() {
        let bench = immediateBench()
        memory.addFile("/A/notes.md", "x")
        bench.left.reload()
        for name in ["docs", "notes.md"] {
            bench.left.moveCursor(toName: name)
            bench.commands.perform(Ids.loadSelectionFromFile)
        }
        #expect(bench.interaction.log.filter { $0.hasPrefix("prompt: Load selection from file []") }.count == 2)
        #expect(bench.jobService.titles.isEmpty)
    }

    /// Names that only read like the entries' still select them; a text that names none
    /// clears the selection, and with none there is nothing to clear.
    @Test
    internal func namesThatReadAlikeAndNamesOfNothing() {
        let bench = immediateBench()
        scratch.pasteboard.clearContents()
        scratch.pasteboard.setString("Cafe\u{301}.txt\r\none.txt", forType: .string)
        bench.commands.perform(Ids.loadSelectionFromClipboard)
        #expect(bench.left.model.selection == ["Café.txt", "one.txt"])
        scratch.pasteboard.clearContents()
        scratch.pasteboard.setString("nothing.txt", forType: .string)
        bench.commands.perform(Ids.loadSelectionFromClipboard)
        #expect(bench.left.model.selection.isEmpty)
        bench.commands.perform(Ids.loadSelectionFromClipboard)
        #expect(bench.left.model.selection.isEmpty)
    }
}
