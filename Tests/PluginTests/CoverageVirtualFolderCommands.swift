import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The commands of virtual folders beyond the other suites: parameters as text, views left
/// where there is nowhere to go, lists that were forgotten, and list files that cannot be read.
@MainActor
@Suite
internal struct CoverageVirtualFolderCommands {
    /// The files: `/A` with a file and a folder, `/B` with a file.
    private let memory = MemoryFileSystem()
    /// The plugin under test.
    private let plugin = VirtualFoldersPlugin()
    /// The kernel with the plugin; the panels show `/A` and `/B`.
    private let bench: TestBench

    /// The kernel's commands.
    private var commands: CommandRegistry { bench.commands }
    /// The panel on `/A`, the source.
    private var left: FakePanel { bench.left }

    /// The files and the kernel.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/B/other.txt", "o")
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
    }

    /// The plugin's file system.
    private func virtual() throws -> VirtualFileSystem {
        try #require(plugin.fileSystem)
    }

    /// A plugin that has not started shows no list; a list shown from a real folder leads back
    /// to it.
    @Test
    internal func listsAreShownFromRealFoldersOnly() throws {
        VirtualFoldersPlugin().show([memory.url("/A/one.txt")], title: "Found", in: left)
        #expect(left.model.directory == memory.url("/A"))
        plugin.show([memory.url("/A/one.txt")], title: "Found", in: left)
        #expect(VirtualLocation(left.model.directory)?.realDirectory == memory.url("/A"))
        // Shown from a virtual folder (the list), the new list leads back to its real folder.
        plugin.show([memory.url("/A/one.txt")], title: "Again", in: left)
        #expect(VirtualLocation(left.model.directory)?.realDirectory == memory.url("/A"))
    }

    /// The branch view takes its parameter as text too: 1 switches it on, and again on changes
    /// nothing.
    @Test
    internal func theParameterAsText() {
        commands.perform(.branchView, .text(" 1 "))
        let shown = left.model.directory
        #expect(VirtualLocation(shown) != nil)
        commands.perform(.branchView, .text("1"))
        #expect(left.model.directory == shown)
    }

    /// A selected branch of nothing is not made.
    @Test
    internal func aSelectedBranchOfNothingIsNotMade() {
        left.model.moveCursor(to: 0)
        commands.perform("cm_LeftDirBranchSel")
        #expect(left.model.directory == memory.url("/A"))
    }

    /// A list without a folder of its own, and nothing under the cursor, has nowhere to go back to.
    @Test
    internal func anEmptyListWithoutOriginHasNowhereToGo() throws {
        var rejected = 0
        commands.onRejected = { rejected += 1 }
        left.show(try virtual().register(files: [], title: "Empty", origin: nil))
        commands.perform(.branchView)
        #expect(rejected == 1 && VirtualLocation(left.model.directory)?.isList == true)
    }

    /// Leaving a selected branch whose folder is gone, or whose list was forgotten, leaves the
    /// selection alone.
    @Test
    internal func leavingWithoutTheFolderOrTheList() throws {
        left.model.setSelected(true, names: ["docs"])
        commands.perform("cm_DirBranchSel")
        left.model.moveCursor(to: 0)
        memory.removeTree("/A")
        commands.perform(.branchView)
        #expect(!left.failures.isEmpty)
        memory.addFile("/A/one.txt", "1")
        left.show(memory.url("/A"))
        left.model.setSelected(true, names: ["one.txt"])
        commands.perform("cm_DirBranchSel")
        for index in 0..<VirtualFileSystem.listLimit {
            _ = try virtual().register(files: [], title: "L\(index)", origin: nil)
        }
        left.model.moveCursor(to: 0)
        left.model.clearSelection()
        commands.perform(.branchView)
        #expect(left.model.directory == memory.url("/A") && left.model.selection.isEmpty)
    }

    /// A list file is found from the home folder when the panel shows a list without a folder;
    /// a cancelled prompt loads nothing; a list file too large is reported.
    @Test
    internal func listFilesFromListsCancelledOrTooLarge() throws {
        left.show(try virtual().register(files: [], title: "Empty", origin: nil))
        commands.perform("LOADLIST", .text("afm-no-such-list.txt"))
        #expect(bench.interaction.log.last == "inform: The list of files could not be loaded.")
        bench.interaction.promptAnswers = [.cancel]
        commands.perform("LOADLIST")
        #expect(bench.jobService.titles.count == 1)
        memory.addFile("/B/big.txt", String(repeating: "x", count: FileListFile.sizeLimit + 1))
        commands.perform("LOADLIST", .location(memory.url("/B/big.txt")))
        #expect(bench.interaction.log.last == "inform: The list of files could not be loaded.")
    }
}
