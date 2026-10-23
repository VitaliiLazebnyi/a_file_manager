import AFMContracts
import AFMKernel
import ClipboardPlugin
import FileOperationsPlugin
import FilePropertiesPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

/// The commands follow what each place allows, not what the file system allows in general.
@MainActor
@Suite
internal struct FileOpsAdoptCapabilities {
    /// A file system with a writable folder A that has a Trash, a writable B and a read-only R.
    internal let memory = MemoryFileSystem()
    /// The kernel with the plugins whose commands change files.
    internal let bench: TestBench

    /// The panels on A and B of `memory`.
    internal init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/B/two.txt")
        memory.addFile("/R/ro.txt")
        // The file system as a whole can only write; one place has a Trash, another nothing at all.
        memory.capabilities = [.write]
        memory.capabilitiesAt = { url in
            url.path.hasPrefix("/R") ? [] : url.path.hasPrefix("/A") ? [.write, .trash] : [.write]
        }
        bench = TestBench(
            plugins: [FileOperationsPlugin(), ClipboardPlugin(), FilePropertiesPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// The commands that change files follow what the folder shown allows.
    @Test
    internal func commandsFollowTheCapabilitiesOfTheFolderShown() {
        bench.left.show(memory.url("/R"))
        bench.left.moveCursor(toName: "ro.txt")
        for id in [CommandID.makeDirectory, .delete, .renameMove, .setAttributes] {
            #expect(!bench.commands.isEnabled(id), "\(id) in a folder nobody may change")
        }
        bench.left.show(memory.url("/A"))
        bench.left.moveCursor(toName: "one.txt")
        for id in [CommandID.makeDirectory, .delete, .renameMove, .setAttributes] {
            #expect(bench.commands.isEnabled(id), "\(id)")
        }
    }

    /// The Trash is offered by what the items' place has, not by the file system as a whole.
    @Test
    internal func theTrashIsOfferedWhereTheItemsAreNotWhereTheFileSystemSaysInGeneral() {
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.choiceAnswers = [1]
        bench.commands.perform(.delete)
        #expect(bench.interaction.log.last?.contains("to the Trash") == true)

        bench.left.show(memory.url("/B"))
        bench.left.moveCursor(toName: "two.txt")
        bench.interaction.choiceAnswers = [1]
        bench.commands.perform(.delete)
        #expect(bench.interaction.log.last?.hasPrefix("choose: Permanently delete") == true)
    }
}
