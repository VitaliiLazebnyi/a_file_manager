import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// The plugin: a window closed before its comparison has come, a quit whose saving fails, and one file named by
/// another plugin.
@MainActor
@Suite
internal struct CovComparePlugin {
    private let memory = MemoryFileSystem()

    /// `/A/a.txt` and `/B/a.txt`, which differ.
    internal init() {
        memory.addFile("/A/a.txt", "one\ntwo\n")
        memory.addFile("/B/a.txt", "one\n2\n")
    }

    /// A window closed while its files are still being read lets its comparison go when it comes.
    @Test
    internal func aWindowClosedBeforeItsComparisonLetsItGo() async {
        var effects = CompareWindowEffects.system
        var presented = 0
        effects.present = { _ in presented += 1 }
        effects.beep = {
            // Silent.
        }
        let plugin = CompareContentPlugin(opensWindows: true, effects: effects)
        defer { plugin.stop() }
        let bench = bench(plugin)
        memory.stallsReads = true
        bench.commands.perform(.compareByContent, .text("mem:/A/a.txt\nmem:/B/a.txt"))
        weak let session = plugin.sessions.first
        autoreleasepool {
            plugin.windows.first?.close()
        }
        #expect(presented == 1 && plugin.windows.isEmpty && plugin.sessions.isEmpty)
        memory.releaseStalls()
        #expect(await CovCompareStage.settle { session == nil })
    }

    /// Quitting with an edit whose saving fails is called off.
    @Test
    internal func aQuitWhoseSavingFailsIsCalledOff() throws {
        let plugin = CompareContentPlugin(opensWindows: false)
        let bench = bench(plugin)
        bench.commands.perform(.compareByContent, .text("mem:/A/a.txt\nmem:/B/a.txt"))
        let session = try #require(plugin.sessions.first)
        session.setEditing(true)
        session.setText("edited", .left, row: 0)
        try CoverageArchivesFSHookedMemory.put(Data("changed meanwhile\n".utf8), at: "/A/a.txt", on: memory)
        bench.interaction.choiceAnswers = [0]
        #expect(!plugin.shouldTerminate() && session.hasUnsavedChanges)
    }

    /// One file named by another plugin is the left one; the right one is to be chosen.
    @Test
    internal func oneFileNamedIsTheLeftOne() throws {
        let plugin = CompareContentPlugin(opensWindows: false)
        let bench = bench(plugin)
        bench.commands.perform(.compareByContent, .text("mem:/A/a.txt"))
        let session = try #require(plugin.sessions.first)
        #expect(session.displayPath(.left) == "mem:/A/a.txt" && session.rightURL == nil)
        #expect(session.status == "Choose two files and press Compare")
    }

    private func bench(_ plugin: CompareContentPlugin) -> TestBench {
        TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
    }
}
