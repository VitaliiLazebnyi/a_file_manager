import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SelectionPlugin

/// Selection with two names that read alike: each is a file of its own.
@MainActor
@Suite
internal struct ToolsAdoptSelection {
    /// The folder `/A` with the two names and another file, and an empty `/B`.
    internal let memory = MemoryFileSystem()

    /// A pasteboard of the test's own.
    private let scratch = ScratchPasteboard()
    /// The pasteboard the plugin reads.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }

    /// The files of the two names that read alike, and a plain one.
    internal init() {
        memory.addFile("/A/" + ToolsAdopt.composed, "12345")
        memory.addFile("/A/" + ToolsAdopt.decomposed, "1")
        memory.addFile("/A/plain.md", "x")
        memory.addDirectory("/B")
    }

    /// A kernel with the plugin, its panels on `/A` and `/B`.
    internal func makeBench() -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: pasteboard, background: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: MemorySettings()
        )
    }

    /// The names of the marked items of a panel, in list order.
    internal func marked(_ model: PanelModel) -> [String] {
        model.items.filter { item in model.isSelected(item) }.map(\.name)
    }

    /// The entries of a folder of the file system in memory, hidden ones too.
    private func listing(_ path: String) -> [FileItem] { (try? memory.list(memory.url(path), showHidden: true)) ?? [] }

    /// A group of a mask marks both names that read alike, and unmarking takes both off.
    @Test
    internal func aGroupMarksBothTwins() {
        let bench = makeBench()
        bench.commands.perform(.selectGroup, .text("*.txt"))
        #expect(bench.left.model.selectionCount == 2)
        #expect(marked(bench.left.model).count == 2)
        bench.commands.perform(.unselectGroup, .text("*.txt"))
        #expect(bench.left.model.selectionCount == 0)
    }

    /// Inverting the marks treats the two names apart.
    @Test
    internal func invertingTreatsTheTwinsApart() {
        let bench = makeBench()
        let model = bench.left.model
        model.setSelected(true, names: [ToolsAdopt.composed])
        #expect(marked(model).map { ToolsAdopt.isExactly($0, ToolsAdopt.composed) } == [true])
        bench.commands.perform(SelectionCommands.invertFiles)
        let names = marked(model)
        #expect(
            names.count == 2 && names.contains { ToolsAdopt.isExactly($0, ToolsAdopt.decomposed) }
                && names.contains("plain.md")
        )
        #expect(!names.contains { ToolsAdopt.isExactly($0, ToolsAdopt.composed) })
    }

    /// A rule answers for each entry, so that only the larger of the two is taken.
    @Test
    internal func aRuleAnswersPerEntry() {
        var type = SelectionType(name: "big")
        type.minSize = 2
        let items = listing("/A")
        let names = SelectionRule(type).matching(among: items, base: memory.url("/A"), now: Date())
        #expect(names.count == 1 && ToolsAdopt.isExactly(names[0], ToolsAdopt.composed))
        // The set a caller may still ask for holds one member for the twins that read alike.
        #expect(SelectionRule(mask: "*.txt").matching(among: items, base: memory.url("/A"), now: Date()).count == 2)
    }

    /// Comparing two folders keeps the two names apart.
    @Test
    internal func comparingKeepsTheTwinsApart() {
        let early = Date(timeIntervalSince1970: 1_000_000)
        func file(_ name: String) -> FileItem {
            FileItem(url: memory.url("/x/" + name), name: name, stat: .init(size: 1, modified: early))
        }
        let marks = DirectoryComparison.compare(
            left: [file(ToolsAdopt.composed), file(ToolsAdopt.decomposed)],
            right: [file(ToolsAdopt.composed)],
            options: .init(mode: .missing)
        )
        #expect(marks.leftNames.count == 1 && ToolsAdopt.isExactly(marks.leftNames[0], ToolsAdopt.decomposed))
        #expect(
            marks.rightNames.isEmpty && marks.sameNames.count == 1
                && ToolsAdopt.isExactly(marks.sameNames[0], ToolsAdopt.composed)
        )
        // Only reading alike is enough where nothing is written exactly like it.
        let alike = DirectoryComparison.compare(
            left: [file(ToolsAdopt.composed)],
            right: [file(ToolsAdopt.decomposed)],
            options: .init(mode: .missing)
        )
        #expect(alike.leftNames.isEmpty && alike.rightNames.isEmpty)
    }

    /// A selection on the clipboard marks the one name it writes.
    @Test
    internal func aSelectionFileNamesTheTwinItWrites() {
        let bench = makeBench()
        pasteboard.clearContents()
        pasteboard.setString(ToolsAdopt.decomposed + "\n", forType: .string)
        bench.commands.perform(SelectionCommands.loadSelectionFromClipboard)
        let names = marked(bench.left.model)
        #expect(names.count == 1 && ToolsAdopt.isExactly(names[0], ToolsAdopt.decomposed))
    }
}
