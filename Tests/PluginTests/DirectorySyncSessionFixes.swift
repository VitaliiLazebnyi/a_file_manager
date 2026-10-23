import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The session of Synchronize directories: cheap toggling and the phase while the job runs.
@MainActor
@Suite
internal struct DirectorySyncSessionFixes {
    /// The file system in memory with the two folders.
    internal let memory = MemoryFileSystem()
    /// The plugin, without windows.
    internal let plugin = DirectorySyncPlugin(opensWindows: false)
    /// The kernel with the panels on the two folders.
    internal let bench: TestBench
    /// A date in the past the files carry.
    internal let early = Date(timeIntervalSince1970: 1_000_000)

    /// A newer file on the left, one in a subfolder on the right, and one the same on both.
    internal init() {
        memory.addFile("/A/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addFile("/B/sub/arrives.txt", "from the right", modified: early)
        memory.addFile("/A/same.txt", "same", modified: early)
        memory.addFile("/B/same.txt", "same", modified: early)
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: MemorySettings()
        )
    }

    /// The session of the command, compared.
    internal func opened() throws -> SyncSession {
        bench.commands.perform(.synchronizeDirectories)
        let session = try #require(plugin.session)
        session.compare()
        return session
    }

    /// Changing actions reports only the rows that changed, and keeps the count of actionable rows right.
    @Test
    internal func togglingTouchesOnlyItsRowsAndKeepsTheCount() throws {
        let session = try opened()
        #expect(session.canSynchronize)
        var touched: [[Int]] = []
        session.onRowsChange = { rows in touched.append(rows) }
        let all = session.visibleRows
        session.setAction(.nothing, rows: all)
        #expect(
            !session.canSynchronize
                && touched == [all.filter { index in session.rows[index].defaultAction != .nothing }]
        )
        // Rows already at the wanted action are not reported again.
        session.setAction(.nothing, rows: all)
        #expect(touched.last?.isEmpty == true)
        let new = try #require(session.rows.indices.first { index in session.rows[index].name == "new.txt" })
        session.toggle(rows: [new])
        #expect(session.canSynchronize && touched.last == [new] && session.positions[new] >= 0)
        #expect(session.groupIndicator(atEntry: session.entries.count - 1).contains("sub/"))
    }

    /// While the job of Synchronize runs, neither Synchronize nor Compare starts again.
    @Test
    internal func neitherSynchronizeNorCompareStartsWhileTheJobRuns() throws {
        let session = try opened()
        var phases: [SyncSession.Phase] = []
        session.onChange = { [weak session] in
            if let session {
                phases.append(session.phase)
            }
        }
        bench.interaction.formAnswers = [.accept]
        bench.interaction.choiceAnswers = [1]
        session.synchronize()
        #expect(phases.contains(.synchronizing) && session.phase == .compared)
        #expect(phases.first == .synchronizing)
    }
}
