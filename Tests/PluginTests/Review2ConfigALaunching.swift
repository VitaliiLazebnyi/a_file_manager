import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The runner with real programs: a login shell is started, as in the program.
@MainActor
@Suite
internal struct Review2ConfigALaunching {
    /// The folders `A` and `B`, and the file the program writes.
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
        try box.folder("A")
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

    /// Lets the main thread run until `done`.
    ///
    /// Only a hang ends the wait without it: on a busy machine other tests may hold the main thread
    /// for a long time, so no shorter limit is set.
    internal func wait(until done: () -> Bool) async {
        #expect(await RunLoopWait.until(done))
    }

    /// A hostile file name reaches the program as it is, in every quoting, and runs nothing.
    @Test
    internal func aHostileFileNameReachesTheProgramAsItIsAndRunsNothing() async throws {
        // The names that ran `touch` before: a quote and a backtick that carry a combining mark.
        let names = ["a\"\u{301};touch PWNED1;\"\u{301}", "`\u{301};touch PWNED2;`\u{301}", "$(touch PWNED3);x", "-n"]
        for name in names { try box.file("A/" + name) }
        bench.left.reload()
        let out = box.url("out.bin").path
        // The panel's folder is where the line runs: a marker would appear in it.
        center.save(
            UserCommand(
                name: "em_show",
                title: "",
                action: CommandAction(command: "printf '%s\\0'", parameters: "%N \"%P%N\" x%Ny > '\(out)'")
            )
        )
        for name in names {
            try? FileManager.default.removeItem(atPath: out)
            bench.left.moveCursor(toName: name)
            bench.commands.perform("em_show")
            func written() -> Data { (try? Data(contentsOf: URL(fileURLWithPath: out))) ?? Data() }
            await wait { written().filter { $0 == 0 }.count == 3 }
            let output = try #require(String(bytes: written(), encoding: .utf8))
            let words = output.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
            let guarded = name.hasPrefix("-") ? "./" + name : name
            let folder = bench.left.model.directory.path
            #expect(
                words.map { Array($0.utf8) }
                    == [guarded, folder + "/" + name, "x" + name + "y"].map { Array($0.utf8) },
                "\(name.debugDescription): \(words.map(\.debugDescription))"
            )
        }
        let created = try FileManager.default.contentsOfDirectory(atPath: box.url("A").path)
            .filter { $0.hasPrefix("PWNED") }
        #expect(created.isEmpty && bench.interaction.log.isEmpty)
    }

    /// A program the shell does not find is reported.
    @Test
    internal func aProgramTheShellDoesNotFindIsReported() async {
        center.save(
            UserCommand(
                name: "em_missing",
                title: "",
                action: CommandAction(command: "afm-no-such-program-\(UUID().uuidString)")
            )
        )
        bench.commands.perform("em_missing")
        await wait { bench.interaction.log.contains { $0.hasPrefix("inform:") } }
        #expect(bench.interaction.log.count == 1 && bench.interaction.log[0].contains("cannot be started"))
    }

    /// A chain stops when its program could not be started; another goes on.
    @Test
    internal func aChainStopsWhenItsProgramCouldNotBeStarted() async {
        var probes = 0
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) { probes += 1 }
        center.save(
            UserCommand(
                name: "em_bad",
                title: "",
                action: CommandAction(command: "afm-no-such-program-\(UUID().uuidString)")
            )
        )
        center.save(UserCommand(name: "em_chain", title: "", action: CommandAction(command: "em_bad, cm_ConfigProbe")))
        center.save(UserCommand(name: "em_good", title: "", action: CommandAction(command: "true")))
        center.save(
            UserCommand(name: "em_chain2", title: "", action: CommandAction(command: "em_good, cm_ConfigProbe"))
        )
        bench.commands.perform("em_chain")
        await wait { bench.interaction.log.contains { $0.contains("cannot be started") } }
        bench.commands.perform("em_chain2")
        await wait { probes == 1 }
        // Only the chain whose program ran went on.
        #expect(probes == 1 && !center.runner.isWaiting)
    }
}
