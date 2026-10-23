import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The session of Synchronize directories keeps two names that read alike apart.
@MainActor
@Suite
internal struct ToolsAdoptSyncSession {
    /// Of two names that read alike, the marked one is the one taken from the panel.
    @Test
    internal func theSelectionOfTwoPanelsKeepsTheTwins() {
        let memory = MemoryFileSystem()
        memory.addFile("/A/" + ToolsAdopt.composed)
        memory.addFile("/A/" + ToolsAdopt.decomposed)
        memory.addDirectory("/B")
        let bench = TestBench(
            plugins: [DirectorySyncPlugin(opensWindows: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: MemorySettings()
        )
        bench.left.model.setSelected(true, names: [ToolsAdopt.decomposed])
        let session = SyncSession(kernel: bench.kernel)
        session.adopt(
            left: bench.left.model,
            right: bench.right.model,
            includeHidden: false,
            readsInBackgroundFrom: SyncSession.backgroundFrom
        )
        #expect(
            session.selectedNames.count == 1 && ToolsAdopt.isExactly(session.selectedNames[0], ToolsAdopt.decomposed)
        )
    }
}
