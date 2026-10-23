import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// Synchronize directories with fake panels on two folders in memory, a scripted user and jobs that
/// run at once; the comparison tool is there for "Compare left & right".
///
/// The left folder has a new file, a newer one, an older one, an equal one and one of the same date
/// that differs; the right one has the other sides of those and a file in a subfolder.
@MainActor
internal struct DirectorySyncFixture {
    /// The two folders.
    internal let memory = MemoryFileSystem()
    /// The plugin, without windows.
    internal let plugin = DirectorySyncPlugin(opensWindows: false)
    /// The comparison tool, without windows.
    internal let compareTool = CompareContentPlugin(opensWindows: false)
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// The kernel with both plugins, its panels on the two folders.
    internal let bench: TestBench
    /// The date the files are dated from.
    internal let early = Date(timeIntervalSince1970: 1_000_000)

    /// The scripted answers of the user, and what was asked.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// The two folders and the bench.
    internal init() {
        memory.addFile("/A/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addFile("/A/update.txt", "newer on the left", modified: early.addingTimeInterval(60))
        memory.addFile("/B/update.txt", "older", modified: early)
        memory.addFile("/A/back.txt", "older", modified: early)
        memory.addFile("/B/back.txt", "newer on the right", modified: early.addingTimeInterval(60))
        memory.addFile("/B/sub/arrives.txt", "from the right", modified: early)
        memory.addFile("/A/same.txt", "same", modified: early)
        memory.addFile("/B/same.txt", "same", modified: early)
        memory.addFile("/A/odd.txt", "left text", modified: early)
        memory.addFile("/B/odd.txt", "right text!", modified: early)
        bench = TestBench(
            plugins: [plugin, compareTool],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// Opens the tool and compares.
    internal func opened() throws -> SyncSession {
        try opened { _ in
            // The options as they are.
        }
    }

    /// Opens the tool, sets it up with `configure` and compares.
    internal func opened(_ configure: (SyncSession) -> Void) throws -> SyncSession {
        bench.commands.perform(.synchronizeDirectories)
        let session = try #require(plugin.session)
        configure(session)
        session.compare()
        return session
    }

    /// The indexes of the session's rows of these names.
    internal func rows(_ session: SyncSession, _ names: String...) -> [Int] {
        session.rows.indices.filter { index in names.contains(session.rows[index].name) }
    }
}
