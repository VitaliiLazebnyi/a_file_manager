import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The tool without a window, where the log goes when no folder is given.
@MainActor
@Suite
internal struct CoverageRenamePluginDefaults {
    /// Without a folder given the log goes to the user's Logs folder, and without windows the clipboard is empty.
    @Test
    internal func theLogGoesToTheUsersLogsFolderAndTheClipboardIsEmpty() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/d/a.txt")
        let plugin = MultiRenamePlugin(opensWindows: false)
        let bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/d"), right: memory.url("/d"))
        bench.left.model.selectAll()
        #expect(bench.commands.perform(.multiRename))
        let session = try #require(plugin.session)
        #expect(session.logURL.path.hasSuffix("Library/Logs/Test/renlog.txt"))
        session.settings.nameMask = "[X+]n"
        #expect(session.rows.first?.newName == "n.txt")
        plugin.stop()
    }
}
