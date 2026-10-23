import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// User commands of the Configuration plugin: the names they are given, and chains that wait
/// for a start menu entry.
@MainActor
@Suite
internal struct ConfigurationAdoption {
    /// A memory file system with the names to mark.
    internal let memory = MemoryFileSystem()
    /// A folder on the disk for the lists and the marker file.
    internal let box: Sandbox

    /// A sandbox folder of its own for each test.
    internal init() throws { box = try Sandbox() }

    /// A user command gets the marked name and not its twin that differs only in normalisation.
    @Test
    internal func aMarkedNameIsNotMarkedForItsNormalisationTwin() throws {
        let (composed, decomposed) = ("caf\u{e9}.txt", "cafe\u{301}.txt")
        memory.addFile("/A/" + composed)
        memory.addFile("/A/" + decomposed)
        memory.addDirectory("/B")
        let plugin = ConfigurationPlugin(
            launchesApplications: false,
            background: nil,
            listFolder: box.url("lists")
        ) { [] }
        let bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        bench.left.model.setSelected(true, names: [decomposed])
        try #require(plugin.center)
            .save(
                UserCommand(name: "em_marked", title: "", action: CommandAction(command: "echo", parameters: "%S"))
            )
        bench.commands.perform("em_marked")
        let line = Array((plugin.launched.first ?? "").utf8)
        func contains(_ text: String) -> Bool {
            let needle = Array(text.utf8)
            return line.indices.contains { line[$0...].starts(with: needle) }
        }
        #expect(contains("cafe\u{301}.txt") && !contains("caf\u{e9}.txt"))
    }

    /// A chain of commands waits for a start menu entry it runs before it goes on.
    @Test
    internal func aStartMenuEntryInAChainIsWaitedFor() async throws {
        _ = try? box.folder("A")
        _ = try? box.folder("B")
        let plugin = ConfigurationPlugin(
            launchesApplications: true,
            background: nil,
            listFolder: box.url("lists")
        ) { [] }
        let bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        let center = try #require(plugin.center)
        let marker = box.url("marker").path
        var draft = center.startMenuDraft()
        draft.insert(
            StartMenuDraft.Row(
                entry: StartMenuEntry(title: "Build", action: CommandAction(command: "sleep 0.3; touch '\(marker)'"))
            ),
            after: nil
        )
        center.commit(draft)
        var probed = false
        var existed = false
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) {
            probed = true
            existed = FileManager.default.fileExists(atPath: marker)
        }
        center.save(
            UserCommand(name: "em_chain", title: "", action: CommandAction(command: "cm_UserMenu1, cm_ConfigProbe"))
        )
        bench.commands.perform("em_chain")
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !probed, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(probed && existed)
    }
}
