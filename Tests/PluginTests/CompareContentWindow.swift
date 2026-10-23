import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// The window itself: opened when the background comparison has found differences, and drawn.
@MainActor
@Suite
internal struct CompareContentWindow {
    /// Two folders with a long text that differs in ten places, an identical pair and a binary pair.
    private static func folders() -> MemoryFileSystem {
        let memory = MemoryFileSystem()
        memory.addFile("/A/a.txt", (0..<500).map { line in "line \(line)" }.joined(separator: "\n"))
        memory.addFile(
            "/B/a.txt",
            (0..<500).map { line in line % 50 == 7 ? "changed \(line)" : "line \(line)" }.joined(separator: "\n")
        )
        memory.addFile("/A/same.txt", "same")
        memory.addFile("/B/same.txt", "same")
        memory.addFile("/A/data.bin", "\u{0}\u{1}binary")
        memory.addFile("/B/data.bin", "\u{0}\u{1}BINARY and more")
        return memory
    }

    /// Lets the main thread run what the comparisons send it until `done` holds, up to `Wait.ceiling`: a comparison
    /// under load may take long, and only a hang reaches the ceiling.
    internal func spin(until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !done() {
            guard Date() < deadline else {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    /// A window opens only for files that differ, several at once, and all close when the plugin stops.
    @Test
    internal func windowOpensForDifferentFilesOnly() async {
        let memory = Self.folders()
        // The windows are made but never put on the desktop: `present` only counts.
        let presenter = StabilityPresenter()
        let windowWatch = StabilityWindows { $0.title.hasPrefix("Compare contents") }
        var effects = CompareWindowEffects.system
        effects.present = { [weak presenter] in presenter?.present($0) }
        effects.beep = {
            // Silent in tests.
        }
        let plugin = CompareContentPlugin(opensWindows: true, effects: effects)
        defer {
            plugin.stop()
            presenter.closeAll()
            #expect(windowWatch.shown.isEmpty && windowWatch.open.isEmpty)
            windowWatch.closeAll()
        }
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        func windows() -> [NSWindow] {
            plugin.windows.compactMap(\.window)
        }

        bench.left.moveCursor(toName: "same.txt")
        bench.commands.perform(.compareByContent)
        #expect(await spin { plugin.sessions.isEmpty })
        #expect(windows().isEmpty && bench.interaction.log == ["inform: Compare contents"])

        bench.left.moveCursor(toName: "a.txt")
        bench.commands.perform(.compareByContent)
        #expect(await spin { !windows().isEmpty && plugin.sessions.first?.phase == .ready })
        #expect(windows().count == 1 && plugin.sessions.count == 1 && plugin.sessions[0].blocks.count == 10)
        windows()[0].contentView?.layoutSubtreeIfNeeded()
        windows()[0].displayIfNeeded()
        plugin.sessions[0].setEditing(true)
        plugin.sessions[0].copy(rows: 7..<8, to: .right)
        windows()[0].displayIfNeeded()
        #expect(plugin.sessions[0].blocks.count == 9)
        plugin.sessions[0].undo()

        // Several windows may be open at once.
        bench.left.moveCursor(toName: "data.bin")
        bench.commands.perform(.compareByContent)
        #expect(await spin { windows().count == 2 && plugin.sessions.last?.phase == .ready })
        #expect(windows().count == 2 && plugin.sessions.last?.isBinary == true && presenter.requests == 3)
        for window in windows() {
            window.displayIfNeeded()
        }
        plugin.stop()
        #expect(windows().isEmpty && plugin.sessions.isEmpty)
    }
}
