import AFMKernel
import AppKit
import Foundation
import NavigationPlugin
import TestSupport
import Testing

@testable import FolderTabsPlugin
@testable import ViewOptionsPlugin

/// Tab files, the clipboard command and background sorting, on a memory file system.
@MainActor
@Suite
internal struct PluginFixes {
    /// The file system both panels show: `/A` with a file and a folder, `/B` with a file.
    internal let memory = MemoryFileSystem()
    private let scratch = ScratchPasteboard()
    /// The pasteboard the navigation plugin reads, private to the test.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The kernel with the tabs, navigation and view options plugins, `/A` on the left and `/B` on the right.
    internal let bench: TestBench

    /// A fresh memory file system and bench for each test.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/B/other.txt", "o")
        bench = TestBench(
            plugins: [FolderTabsPlugin(), NavigationPlugin(pasteboard: scratch.pasteboard), ViewOptionsPlugin()],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Saving the tabs replaces a tab file in one step and leaves a folder of that name alone.
    @Test
    internal func aTabFileIsReplacedInOneStepAndOnlyIfItIsAFile() {
        bench.commands.perform("SAVETABS", .location(memory.url("/A/my.tab")))
        let first = memory.contents("/A/my.tab")
        #expect(first?.contains("[activetabs]") == true)
        // Saving again replaces the file, and nothing temporary is left beside it.
        bench.left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        bench.interaction.choiceAnswers = [0]
        bench.commands.perform("SAVETABS", .location(memory.url("/A/my.tab")))
        #expect(memory.contents("/A/my.tab") != first && memory.contents("/A/my.tab")?.contains("docs") == true)
        #expect(
            (try? memory.list(memory.url("/A"), showHidden: true).map(\.name).sorted()) == [
                "docs", "my.tab", "one.txt"
            ]
        )
        // A folder of that name is not a tab file: it is neither removed nor read.
        memory.addDirectory("/A/folder.tab")
        bench.commands.perform("SAVETABS", .location(memory.url("/A/folder.tab")))
        #expect(memory.item(at: memory.url("/A/folder.tab"))?.isDirectory == true)
        #expect(bench.interaction.log.last?.contains("could not be saved") == true)
    }

    /// A file larger than a tab file can be is not loaded, and the user is told.
    @Test
    internal func aFileTooLargeToBeATabFileIsNotLoaded() {
        memory.addFile("/A/huge.tab", String(repeating: "x", count: FolderTabsPlugin.tabFileLimit + 10))
        let before = bench.left.tabs.count
        bench.commands.perform("OPENTABS", .location(memory.url("/A/huge.tab")))
        #expect(bench.left.tabs.count == before && bench.interaction.log.last?.contains("could not be loaded") == true)
    }

    /// The clipboard command is offered for any text on the pasteboard and goes to its first line.
    @Test
    internal func theClipboardCommandIsOfferedForAnyTextAndReadsOnlyTheFirstLine() {
        #expect(!bench.commands.isEnabled("afm_CdFromClipboard"))
        pasteboard.clearContents()
        pasteboard.setString(
            "\n\n  mem:/A/docs  \n" + String(repeating: "more lines\n", count: 50_000),
            forType: .string
        )
        #expect(bench.commands.isEnabled("afm_CdFromClipboard"))
        bench.commands.perform("afm_CdFromClipboard")
        #expect(bench.left.model.directory.path == "/A/docs")
    }

    /// A long list is sorted in the background, a second sort command starting from the first one's order.
    @Test
    internal func aLongListIsSortedInTheBackgroundAndAShortOneAtOnce() async throws {
        let model = bench.left.model
        bench.commands.perform("cm_SrcBySize")
        #expect(model.sort == ListOrder(key: .size, descending: true))

        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let long = (0..<(ViewOptionsPlugin.backgroundSortThreshold + 500))
            .map { index in
                FileItem(
                    url: memory.url("/A/f\(index).txt"),
                    name: "f\(index).txt",
                    stat: .init(size: Int64(index % 977))
                )
            }
        model.show(Listing(directory: memory.url("/A"), items: long, parent: root, root: root))
        bench.commands.perform("cm_SrcByName")
        // Two commands in a row: the second starts from the order the first is on its way to.
        bench.commands.perform("cm_SrcNegOrder")
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while model.sort != ListOrder(key: .name, descending: true), Date() < patience {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.sort == ListOrder(key: .name, descending: true))
        #expect(model.items == Sorter.sort(long, by: ListOrder(key: .name, descending: true)))
    }
}
