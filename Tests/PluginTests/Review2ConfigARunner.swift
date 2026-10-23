import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// User commands as the runner performs them (review 2): values stay values from one command
/// to the next, loops end, and what cannot run says so.
@MainActor
@Suite
internal struct Review2ConfigARunner {
    /// The folders `A` (holding `one.txt`) and `B`, and the list folders.
    internal let box: Sandbox
    /// The settings of the program.
    internal let settings = MemorySettings()

    /// The folders of the test.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt")
        try box.folder("B")
    }

    /// A plugin that launches nothing and works on the main thread, started in a program over `A` and `B`.
    internal func bench() -> (plugin: ConfigurationPlugin, bench: TestBench) {
        let plugin = ConfigurationPlugin(launchesApplications: false, background: nil, listFolder: box.url("lists")) {
            []
        }
        let bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        return (plugin, bench)
    }

    /// The configuration of a started `plugin`.
    internal func center(of plugin: ConfigurationPlugin) throws -> ConfigurationCenter {
        try #require(plugin.center)
    }

    /// Saves a user command `name` without a title that runs `command` without parameters.
    internal func define(_ center: ConfigurationCenter, _ name: String, _ command: String) {
        define(center, name, command, "")
    }

    /// Saves a user command `name` without a title that runs `command` with `parameters`.
    internal func define(_ center: ConfigurationCenter, _ name: String, _ command: String, _ parameters: String) {
        center.save(UserCommand(name: name, title: "", action: CommandAction(command: command, parameters: parameters)))
    }

    /// Lets the main thread run until `done`.
    ///
    /// Only a hang ends the wait without it: on a busy machine other tests may hold the main thread
    /// for a long time, so no shorter limit is set.
    internal func wait(until done: () -> Bool) async {
        #expect(await RunLoopWait.until(done))
    }

    /// Commands that call each other across a wait are stopped, and nothing is left waiting.
    @Test
    internal func commandsThatCallEachOtherAcrossAWaitAreStopped() async throws {
        let (plugin, bench) = bench()
        let center = try center(of: plugin)
        define(center, "em_a", "cm_wait 1, em_b")
        define(center, "em_b", "cm_wait 1, em_a")
        bench.commands.perform("em_a")
        await wait { bench.interaction.log.contains { $0.contains("calls itself") } }
        #expect(bench.interaction.log == ["inform: “a” calls itself"])
        // Nothing is left waiting: the loop has ended.
        await wait { !center.runner.isWaiting }
        #expect(!center.runner.isWaiting && bench.interaction.log.count == 1)
    }

    /// A Start menu entry that calls itself across a wait is stopped too.
    @Test
    internal func aStartMenuEntryThatCallsItselfIsStoppedToo() async throws {
        let (plugin, bench) = bench()
        let center = try center(of: plugin)
        var draft = center.startMenuDraft()
        draft.insert(
            StartMenuDraft.Row(
                entry: StartMenuEntry(title: "Loop", action: CommandAction(command: "cm_wait 1, cm_UserMenu1"))
            ),
            after: nil
        )
        center.commit(draft)
        bench.commands.perform("cm_UserMenu1")
        await wait { bench.interaction.log.contains { $0.contains("calls itself") } }
        #expect(bench.interaction.log == ["inform: “Loop” calls itself"])
    }

    /// A run stops after a fixed number of steps and refuses commands nested too deeply.
    @Test
    internal func aRunHasABoundedNumberOfSteps() throws {
        let (plugin, bench) = bench()
        let center = try center(of: plugin)
        var probes = 0
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) { probes += 1 }
        define(
            center,
            "em_many",
            Array(repeating: "cm_ConfigProbe", count: CommandRunner.stepLimit + 50).joined(separator: ",")
        )
        bench.commands.perform("em_many")
        #expect(probes == CommandRunner.stepLimit && bench.interaction.log == ["inform: “many” was stopped"])
        // Commands nested deeper than the limit are refused, not run.
        for level in 0..<(CommandRunner.depthLimit + 4) { define(center, "em_n\(level)", "em_n\(level + 1)") }
        bench.commands.perform("em_n0")
        #expect(bench.interaction.log.last?.contains("is nested too deeply") == true)
    }

    /// A chain that waits can be stopped by Stop User Commands; a later chain runs as usual.
    @Test
    internal func aWaitingChainCanBeStopped() async throws {
        let (plugin, bench) = bench()
        let center = try center(of: plugin)
        var probes = 0
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) { probes += 1 }
        define(center, "em_slow", "cm_wait 3600000, cm_ConfigProbe")
        let stop = ConfigurationPlugin.stopUserCommands
        #expect(!bench.commands.isEnabled(stop))
        bench.commands.perform("em_slow")
        #expect(center.runner.isWaiting && bench.commands.isEnabled(stop))
        bench.commands.perform(stop)
        #expect(!center.runner.isWaiting && !bench.commands.isEnabled(stop) && probes == 0)
        // A chain started afterwards runs as usual.
        define(center, "em_quick", "cm_wait 1, cm_ConfigProbe")
        bench.commands.perform("em_quick")
        await wait { probes == 1 }
        #expect(probes == 1)
    }

    /// A name handed from one user command to the next is neither expanded again nor unquoted.
    @Test
    internal func aNameHandedFromOneCommandToTheNextStaysAName() throws {
        let hostile = "%Q$(touch M) %N;x"
        try box.file("A/" + hostile)
        let (plugin, bench) = bench()
        let center = try center(of: plugin)
        define(center, "em_inner", "echo")
        define(center, "em_words", "tool", "/L=%A1 [%A]")
        define(center, "em_outer", "em_inner", "%N")
        define(center, "em_outer2", "em_words", "-v %N")
        bench.left.moveCursor(toName: hostile)
        bench.commands.perform("em_outer")
        bench.commands.perform("em_outer2")
        // The name is neither read for placeholders again nor left without its quotes.
        #expect(plugin.launched == ["echo \"%Q\\$(touch M) %N;x\"", "tool /L=-v [-v \"%Q\\$(touch M) %N;x\"]"])
    }

    /// A line that cannot hold a name safely (backticks, `$'...'`, a here-document, a name of two lines) is not run.
    @Test
    internal func aLineThatCannotTakeANameSafelyIsNotRun() throws {
        let (plugin, bench) = bench()
        let center = try center(of: plugin)
        define(center, "em_tick", "echo", "`basename %N`")
        define(center, "em_ansi", "echo", "$'%N'")
        define(center, "em_here", "cat <<EOF", "%N")
        define(center, "em_fine", "echo", "\"$(basename %N)\"")
        bench.left.moveCursor(toName: "one.txt")
        for name in ["em_tick", "em_ansi", "em_here"] {
            bench.commands.perform(CommandID(rawValue: name))
            #expect(bench.interaction.log.last == "inform: “\(name.dropFirst(3))” was not run")
        }
        #expect(plugin.launched.isEmpty)
        bench.commands.perform("em_fine")
        #expect(plugin.launched == ["echo \"$(basename one.txt)\""] && bench.interaction.log.count == 3)
        // A list with a name of two lines is not written, and the command is not run.
        _ = try? box.file("A/two\nlines.txt")
        bench.left.reload()
        define(center, "em_list", "cat", "%L")
        bench.commands.perform(.selectAll)
        bench.commands.perform("em_list")
        #expect(bench.interaction.log.last == "inform: “list” was not run" && plugin.launched.count == 1)
        #expect(!FileManager.default.fileExists(atPath: box.url("lists").path))
    }

    /// The marked names of a long list are gathered in the background; names that read the same stay apart.
    @Test
    internal func theMarkedNamesOfALongListAreGatheredInTheBackground() async throws {
        let memory = MemoryFileSystem()
        let count = CommandRunner.backgroundSelectionThreshold + 3
        for number in 0..<count { memory.addFile("/Big/f\(number) x.txt") }
        memory.addDirectory("/B")
        let plugin = ConfigurationPlugin(
            launchesApplications: false,
            background: .global(qos: .userInitiated),
            listFolder: box.url("lists-big")
        ) {
            []
        }
        let bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/Big"),
            right: memory.url("/B")
        )
        let center = try center(of: plugin)
        define(center, "em_all", "tool", "%S")
        define(center, "em_cursor", "tool", "%N")
        bench.commands.perform(.selectAll)
        bench.left.moveCursor(toName: "f1 x.txt")
        bench.commands.perform("em_all")
        // A text without a code for the marked names does not wait for them.
        bench.commands.perform("em_cursor")
        #expect(plugin.launched == ["tool \"f1 x.txt\""])
        await wait { plugin.launched.count == 2 }
        let words = (plugin.launched.last ?? "").components(separatedBy: "\" \"")
        #expect(words.count == count && words.first == "tool \"" + bench.left.model.items[0].name)
        // Two marked names that read the same are told apart by the panel's model, as before.
        let (composed, decomposed) = ("caf\u{e9}.txt", "cafe\u{301}.txt")
        memory.addFile("/Big/" + composed)
        memory.addFile("/Big/" + decomposed)
        bench.left.reload()
        bench.left.model.setSelection(names: [])
        bench.left.model.setSelected(true, names: [decomposed, "f2 x.txt"])
        bench.commands.perform("em_all")
        await wait { plugin.launched.count == 3 }
        let line = Array((plugin.launched.last ?? "").utf8)
        func contains(_ text: String) -> Bool { line.indices.contains { line[$0...].starts(with: Array(text.utf8)) } }
        #expect(contains("cafe\u{301}.txt") && !contains("caf\u{e9}.txt") && contains("f2 x.txt"))
    }

    /// The selection is gathered only for a text with a code that needs it.
    @Test
    internal func theSelectionIsGatheredOnlyForATextThatAsksForIt() {
        #expect(ParameterExpander.usesSelection([.text("%S")]) && ParameterExpander.usesSelection([.text("a %P%s")]))
        #expect(
            ParameterExpander.usesSelection([.text("%L")]) && ParameterExpander.usesSelection([.text("%C1")])
                && ParameterExpander.usesSelection([.text("%UF")])
        )
        #expect(
            !ParameterExpander.usesSelection([.text("%P%N %T%M %%S %O.%E")])
                && !ParameterExpander.usesSelection([.value("%S")])
        )
    }

    /// An application path with a space is opened with `open -a` as one word.
    @Test
    internal func anApplicationPathWithASpaceIsOneWord() throws {
        let app = try box.folder("Apps/My App.app")
        let line: [ExpandedPiece] = [.text("\"\(app.path)\" --flag "), .value("a b")]
        let opened = CommandRunner.startLine(for: line)
        #expect(opened == [.text("/usr/bin/open -a "), .value(app.path), .text(" --flag "), .value("a b")])
        #expect(ShellLine.display(opened) == "/usr/bin/open -a \"\(app.path)\" --flag \"a b\"")
        // A line that is no application stays as it is.
        #expect(CommandRunner.startLine(for: [.text("ls -l")]) == [.text("ls -l")])
        let missing: [ExpandedPiece] = [.text("\"\(box.url("Apps/None.app").path)\" x")]
        #expect(CommandRunner.startLine(for: missing) == missing)
        #expect(ShellWords.firstWord(of: [.text("  \"a b\"c d e")]).word == [.text("\"a b\"c")])
        #expect(
            ShellWords.unquoted(ShellWords.firstWord(of: [.text("pre"), .value("x y"), .text("post rest")]).word)
                == "prex ypost"
        )
    }

    /// List files are removed only when they are old enough that no program still reads them.
    @Test
    internal func listFilesOfARunThatQuitsAreKeptWhileAProgramMayReadThem() throws {
        let made = bench()
        let runner = CommandRunner(
            kernel: made.bench.kernel,
            launchesApplications: false,
            background: nil,
            listFolder: box.url("lists2")
        )
        let folder = try box.folder("lists2")
        let old = try box.file("lists2/list-old.txt")
        let fresh = try box.file("lists2/list-new.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-CommandRunner.defaultListGrace * 3)],
            ofItemAtPath: old.path
        )
        runner.removeListFilesNow()
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-CommandRunner.defaultListGrace * 3)],
            ofItemAtPath: fresh.path
        )
        runner.removeListFilesNow()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
