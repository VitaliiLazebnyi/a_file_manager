import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// Printing file lists and files: the questions that can be cancelled, a list that cannot be written, the pages the
/// printer gets, and files sent to a printer program that fails.
@MainActor
@Suite
internal struct CovSysToolsPrinting {
    private let box: Sandbox
    private let memory = MemoryFileSystem()
    private let recorder = CovSysToolsDesktop()

    /// The files: `A/one.txt`, `A/two.txt` and `B` on the disk, `/M/one.txt`, `/M/list.txt` and `/M/sub` in memory.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        try box.folder("B")
        memory.addFile("/M/one.txt", "1")
        memory.addFile("/M/list.txt", "old")
        memory.addDirectory("/M/sub")
    }

    // MARK: File lists

    /// Cancelling the depth or the mask of a list with subfolders prints nothing.
    @Test
    internal func cancellingTheQuestionsOfAListWithSubfoldersPrintsNothing() {
        let (bench, _) = memoryBench(recorder.desktop())
        bench.commands.perform(SystemToolsCommands.printListWithSubfolders)
        bench.interaction.promptAnswers = [.text("1"), .cancel]
        bench.commands.perform(SystemToolsCommands.printListWithSubfolders)
        #expect(bench.interaction.forms.isEmpty && bench.interaction.log.count == 3)
    }

    /// An output remembered that the dialog does not have starts at the printer; a number of lines that is no number
    /// keeps the remembered one; the printer gets the pages without centering.
    @Test
    internal func oddAnswersFallBackAndThePrinterGetsThePages() throws {
        let (bench, tools) = memoryBench(recorder.desktop())
        bench.kernel.settings.set(7, forKey: SystemTools.printOutputKey)
        bench.kernel.settings.set(40, forKey: SystemTools.printLinesKey)
        bench.interaction.formAnswers = [.values(["output": .index(9), "lines": .text("many")])]
        bench.commands.perform(SystemToolsCommands.printList)
        #expect(bench.interaction.forms.first?.last?.initialValue == .index(0))
        #expect(tools.log == ["print: 1 pages"])
        #expect(bench.kernel.settings.index(SystemTools.printLinesKey, default: 0) == 40)
        let operation = try #require(recorder.printed.value.first)
        #expect(operation.view is PagePrintView && operation.jobTitle == "mem:/M")
        #expect(!operation.printInfo.isHorizontallyCentered && !operation.printInfo.isVerticallyCentered)
    }

    /// A text file needs a name: cancelled or empty, nothing is written.
    @Test
    internal func aTextFileNeedsAName() {
        let (bench, tools) = memoryBench(recorder.desktop())
        bench.interaction.formAnswers = [.values(["output": .index(1)]), .values(["output": .index(1)])]
        bench.interaction.promptAnswers = [.cancel, .text("  ")]
        bench.commands.perform(SystemToolsCommands.printList)
        bench.commands.perform(SystemToolsCommands.printList)
        #expect(tools.log.isEmpty && memory.contents("/M/list.txt") == "old")
    }

    /// A list read while cancelled is neither saved nor shown.
    @Test
    internal func aCancelledListIsNotShown() {
        let tools = SystemToolsPlugin(desktop: recorder.desktop())
        let bench = CoverageSmallBench(
            .cancelled,
            plugins: [tools],
            fileSystems: [memory],
            left: memory.url("/M"),
            right: memory.url("/M")
        )
        bench.interaction.formAnswers = [.values(["output": .index(2)])]
        bench.commands.perform(SystemToolsCommands.printList)
        #expect(bench.interaction.log == ["form: Print directory"] && tools.log.isEmpty)
    }

    /// Refusing to overwrite keeps the old file and reports nothing.
    @Test
    internal func refusingToOverwriteKeepsTheOldFile() {
        let (bench, tools) = memoryBench(recorder.desktop())
        bench.interaction.formAnswers = [.values(["output": .index(1)])]
        bench.interaction.promptAnswers = [.text("list.txt")]
        bench.interaction.choiceAnswers = [1]
        bench.commands.perform(SystemToolsCommands.printList)
        #expect(memory.contents("/M/list.txt") == "old" && tools.log.isEmpty)
        #expect(bench.interaction.log.last == "choose: Overwrite: / mem:/M/list.txt")
    }

    /// A list that cannot be written is reported, and nothing is left behind.
    @Test
    internal func aListThatCannotBeWrittenIsReported() throws {
        let locked = try box.folder("Locked")
        try box.file("Locked/in.txt", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let (bench, tools) = localBench(recorder.desktop(), left: locked)
        bench.interaction.formAnswers = [.values(["output": .index(1)])]
        bench.interaction.promptAnswers = [.text("list.txt")]
        bench.commands.perform(SystemToolsCommands.printList)
        #expect(bench.interaction.log.last == "inform: The file list cannot be saved!" && tools.log.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == ["in.txt"])
    }

    /// The pages lie one below the other, each where its rectangle says, and a page is drawn only when asked for.
    @Test
    internal func thePagesAreDrawnWhereTheirRectanglesAre() throws {
        let view = PagePrintView(pages: [["first", "line"], ["second"]], linesPerPage: 10, printInfo: NSPrintInfo())
        #expect(view.isFlipped && PagePrintView(coder: NSCoder()) == nil)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range == NSRange(location: 1, length: 2))
        let (first, second) = (view.rectForPage(1), view.rectForPage(2))
        #expect(first.minY == 0 && second.minY == first.maxY && view.bounds.height == second.maxY)
        let (alone, both) = (try ink(of: view, in: first), try ink(of: view, in: view.bounds))
        #expect(alone > 0 && both > alone)
    }

    // MARK: Files

    /// Several files are named by count in the question when they are many; the printer program gets them all.
    @Test
    internal func severalFilesAreCountedWhenTheyAreMany() throws {
        for number in 0..<9 {
            try box.file("Many/file\(number).txt", "\(number)")
        }
        let (bench, tools) = localBench(recorder.desktop(), left: box.url("A"))
        bench.left.model.setSelection(names: ["one.txt", "two.txt"])
        bench.interaction.choiceAnswers = [0, 0]
        bench.commands.perform(SystemToolsCommands.printFile)
        #expect(bench.interaction.log.last == "choose: Print / Print 2 files on the default printer?")
        #expect(tools.log == ["print-file: one.txt, two.txt"])
        bench.left.show(box.url("Many"))
        bench.left.model.selectAll()
        bench.commands.perform(SystemToolsCommands.printFile)
        #expect(tools.log.last == "print-file: 9 files")
    }

    /// A printer program that fails, or cannot start, is reported and nothing is logged as printed.
    @Test
    internal func aPrinterThatFailsIsReported() {
        for printer in ["/usr/bin/false", box.url("none").path] {
            let (bench, tools) = localBench(
                recorder.desktop(printer: URL(fileURLWithPath: printer)),
                left: box.url("A")
            )
            bench.left.moveCursor(toName: "one.txt")
            bench.interaction.choiceAnswers = [0]
            bench.commands.perform(SystemToolsCommands.printFile)
            #expect(bench.interaction.log.last == "inform: one.txt cannot be printed!" && tools.log.isEmpty)
        }
    }

    /// The marked files of a long list are picked out in a job of their own, and the printer program is given them
    /// a few hundred at a time (the system starts no program with more than 4,096 arguments).
    @Test
    internal func theFilesOfALongListArePrintedInParts() throws {
        let folder = try box.folder("Long")
        for number in 0...SystemTools.backgroundSelectionThreshold {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(number)").path, contents: nil)
        }
        // The printer program writes down how many files it was given each time.
        let counts = box.url("counts")
        let printer = try box.file("printer", "#!/bin/sh\necho $# >> '\(counts.path)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: printer.path)
        let (bench, tools) = localBench(recorder.desktop(printer: printer), left: folder)
        bench.left.model.selectAll()
        bench.interaction.choiceAnswers = [0]
        bench.commands.perform(SystemToolsCommands.printFile)
        let total = SystemTools.backgroundSelectionThreshold + 1
        #expect(tools.log == ["print-file: \(total) files"])
        let given = (box.read("counts") ?? "").split(separator: "\n").compactMap { Int($0) }
        #expect(given.reduce(0, +) == total && given.count > 1)
        #expect(given.allSatisfy { $0 <= SystemTools.filesPerPrint })
    }

    /// A bench showing the memory folder `/M` on the left.
    private func memoryBench(_ desktop: ToolsDesktop) -> (TestBench, SystemToolsPlugin) {
        let tools = SystemToolsPlugin(desktop: desktop)
        let bench = TestBench(
            plugins: [tools],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/M"),
            right: box.url("B")
        )
        return (bench, tools)
    }

    /// A bench showing the folder `left` of the disk on the left.
    private func localBench(_ desktop: ToolsDesktop, left: URL) -> (TestBench, SystemToolsPlugin) {
        let tools = SystemToolsPlugin(desktop: desktop)
        let bench = TestBench(plugins: [tools], fileSystems: [LocalFileSystem()], left: left, right: box.url("B"))
        return (bench, tools)
    }

    /// How many pixels are drawn on when `view` draws `rect` alone.
    private func ink(of view: NSView, in rect: NSRect) throws -> Int {
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: image)
        return (0..<image.pixelsHigh)
            .reduce(0) { count, row in
                count + (0..<image.pixelsWide).count { (image.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0 }
            }
    }
}
