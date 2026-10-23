import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Multi-Rename follows what the file system of each panel's folder can do.
@MainActor
@Suite
internal struct ToolsAdoptMultiRename {
    /// The command is offered only where the folder of the files can be written.
    @Test
    internal func theToolFollowsTheCapabilitiesOfTheFolderItIsIn() {
        let memory = MemoryFileSystem()
        memory.addFile("/open/a.txt")
        memory.addFile("/locked/b.txt")
        memory.capabilitiesAt = { $0.path.hasPrefix("/locked") ? [] : [.write] }
        let bench = TestBench(
            plugins: [MultiRenamePlugin(opensWindows: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/open"),
            right: memory.url("/locked"),
            settings: MemorySettings()
        )
        bench.left.model.selectAll()
        bench.right.model.selectAll()
        #expect(bench.commands.isEnabled(.multiRename))
        bench.right.focus()
        #expect(!bench.commands.isEnabled(.multiRename))
    }
}
