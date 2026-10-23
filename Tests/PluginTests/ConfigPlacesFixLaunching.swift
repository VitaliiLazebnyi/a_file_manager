import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Programs are started by the runner itself, not through the command line's job.
@MainActor
@Suite
internal struct ConfigPlacesFixLaunching {
    /// The folders `A` (holding `one.txt`) and `B`, and the marker files the programs write.
    internal let box: Sandbox
    /// The plugin, which really launches what it runs.
    internal let plugin: ConfigurationPlugin
    /// The program the plugin runs in, `A` on the left and `B` on the right.
    internal let bench: TestBench
    /// The plugin's configuration, there once the plugin has started.
    internal let center: ConfigurationCenter

    /// The bench over the two folders, with the plugin started.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt")
        try box.folder("B")
        plugin = ConfigurationPlugin(launchesApplications: true, background: nil, listFolder: box.url("lists")) {
            []
        }
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        center = try #require(plugin.center)
    }

    /// Lets the main actor run, so what the runner hands back to the main thread arrives.
    internal func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// The next step of a chain starts only after the program of the step before has ended.
    @Test
    internal func aChainWaitsForTheProgramBeforeItsNextStep() async {
        let marker = box.url("marker").path
        center.save(
            UserCommand(name: "em_build", title: "", action: CommandAction(command: "sleep 0.3; touch '\(marker)'"))
        )
        // The next step looks for the file the program writes: it must exist by then.
        var existed: [Bool] = []
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) {
            existed.append(FileManager.default.fileExists(atPath: marker))
        }
        center.save(
            UserCommand(name: "em_chain", title: "", action: CommandAction(command: "em_build, cm_ConfigProbe"))
        )
        bench.commands.perform("em_chain")
        await wait { !existed.isEmpty }
        #expect(existed == [true])
    }

    /// A launched program shows no job and leaves no entry in the command line's history.
    @Test
    internal func aLaunchIsNoJobAndNoHistoryEntry() async {
        let marker = box.url("marker2").path
        center.save(UserCommand(name: "em_touch", title: "", action: CommandAction(command: "touch '\(marker)'")))
        bench.commands.perform("em_touch")
        #expect(!bench.jobService.titles.contains { $0.hasPrefix("Running") })
        await wait { FileManager.default.fileExists(atPath: marker) }
        #expect(FileManager.default.fileExists(atPath: marker))
        #expect(bench.kernel.settings.data(forKey: "systemTools.history") == nil)
    }

    /// A program that cannot start, because its start folder is missing, is reported.
    @Test
    internal func aLaunchThatCannotStartIsReported() async {
        center.save(
            UserCommand(
                name: "em_nowhere",
                title: "",
                action: CommandAction(command: "true", startPath: "/nonexistent-folder-afm")
            )
        )
        bench.commands.perform("em_nowhere")
        await wait { bench.interaction.log.contains { $0.hasPrefix("inform:") } }
        #expect(bench.interaction.log.contains { $0.hasPrefix("inform:") && $0.contains("cannot be started") })
    }
}
