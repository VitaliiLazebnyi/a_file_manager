import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The window itself: built, filled by a comparison that runs in the background, and drawn.
@MainActor
@Suite
internal struct DirectorySyncWindow {
    /// The window is shown, filled by a comparison by content in the background, drawn, and closed by `stop`.
    @Test
    internal func windowShowsABackgroundComparison() async throws {
        let memory = MemoryFileSystem()
        for index in 0..<40 {
            memory.addFile("/A/d\(index % 4)/f\(index).txt", "left \(index)")
            if !index.isMultiple(of: 3) { memory.addFile("/B/d\(index % 4)/f\(index).txt", "left \(index)") }
        }
        let plugin = DirectorySyncPlugin()
        let presenter = StabilityPresenter()
        plugin.present = presenter.present
        defer { presenter.closeAll() }
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        bench.commands.perform(.synchronizeDirectories)
        let session = try #require(plugin.session)
        let window = presenter.open.first { $0.title == "Synchronize directories" }
        #expect(window != nil)
        session.options.byContent = true
        session.compare()
        #expect(session.phase == .comparing)
        // The result comes back over the main queue, which this test shares with every other test
        // of the process: waited for until it is there (the ceiling only ends a comparison that hangs).
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while session.phase != .compared, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(session.phase == .compared && session.rows.count == 40 && session.entries.count == 44)
        #expect(session.status == "Files found: 40  (Identical: 26, Different: 0, Unique left: 14, Unique right: 0)")
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        session.show = [.copyToRight, .duplicates, .singles]
        session.setAction(.nothing, rows: session.visibleRows)
        window?.displayIfNeeded()
        #expect(!session.canSynchronize)
        plugin.stop()
        #expect(!presenter.isOpen(window))
    }
}
