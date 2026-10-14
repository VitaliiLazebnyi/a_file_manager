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
@MainActor @Suite struct Review2ConfigARunner {
    let box: Sandbox
    let settings = MemorySettings()

    init() throws {
        box = try Sandbox()
        try box.file("A/one.txt")
        try box.folder("B")
    }

    func bench(launches: Bool = false) -> (plugin: ConfigurationPlugin, bench: TestBench) {
        let plugin = ConfigurationPlugin(
            launchesApplications: launches, background: nil, listFolder: box.url("lists"), settingsKeys: { [] })
        let bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin], fileSystems: [LocalFileSystem()],
            left: box.url("A"), right: box.url("B"), settings: settings)
        return (plugin, bench)
    }

    func define(_ plugin: ConfigurationPlugin, _ name: String, _ command: String, _ parameters: String = "") {
        plugin.center!.save(
            UserCommand(name: name, title: "", action: CommandAction(command: command, parameters: parameters)))
    }

    /// Lets the main actor run until `done`, for at most a minute.
    func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func commandsThatCallEachOtherAcrossAWaitAreStopped() async {
        let (plugin, bench) = bench()
        define(plugin, "em_a", "cm_wait 1, em_b")
        define(plugin, "em_b", "cm_wait 1, em_a")
        bench.commands.perform("em_a")
        await wait { bench.interaction.log.contains { $0.contains("calls itself") } }
        #expect(bench.interaction.log == ["inform: “a” calls itself"])
        // Nothing is left waiting: the loop has ended.
        await wait { !plugin.center!.runner.isWaiting }
        #expect(!plugin.center!.runner.isWaiting && bench.interaction.log.count == 1)
    }

    @Test func aStartMenuEntryThatCallsItselfIsStoppedToo() async {
        let (plugin, bench) = bench()
        var draft = plugin.center!.startMenuDraft()
        draft.insert(
            StartMenuDraft.Row(
                entry: StartMenuEntry(title: "Loop", action: CommandAction(command: "cm_wait 1, cm_UserMenu1"))),
            after: nil)
        plugin.center!.commit(draft)
        bench.commands.perform("cm_UserMenu1")
        await wait { bench.interaction.log.contains { $0.contains("calls itself") } }
        #expect(bench.interaction.log == ["inform: “Loop” calls itself"])
    }

    @Test func aRunHasABoundedNumberOfSteps() {
        let (plugin, bench) = bench()
        var probes = 0
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) { probes += 1 }
        define(
            plugin, "em_many",
            Array(repeating: "cm_ConfigProbe", count: CommandRunner.stepLimit + 50).joined(separator: ","))
        bench.commands.perform("em_many")
        #expect(probes == CommandRunner.stepLimit && bench.interaction.log == ["inform: “many” was stopped"])
        // Commands nested deeper than the limit are refused, not run.
        for level in 0..<(CommandRunner.depthLimit + 4) { define(plugin, "em_n\(level)", "em_n\(level + 1)") }
        bench.commands.perform("em_n0")
        #expect(bench.interaction.log.last?.contains("is nested too deeply") == true)
    }

    @Test func aWaitingChainCanBeStopped() async {
        let (plugin, bench) = bench()
        var probes = 0
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) { probes += 1 }
        define(plugin, "em_slow", "cm_wait 3600000, cm_ConfigProbe")
        let stop = ConfigurationPlugin.stopUserCommands
        #expect(!bench.commands.isEnabled(stop))
        bench.commands.perform("em_slow")
        #expect(plugin.center!.runner.isWaiting && bench.commands.isEnabled(stop))
        bench.commands.perform(stop)
        #expect(!plugin.center!.runner.isWaiting && !bench.commands.isEnabled(stop) && probes == 0)
        // A chain started afterwards runs as usual.
        define(plugin, "em_quick", "cm_wait 1, cm_ConfigProbe")
        bench.commands.perform("em_quick")
        await wait { probes == 1 }
        #expect(probes == 1)
    }

    @Test func aNameHandedFromOneCommandToTheNextStaysAName() throws {
        let hostile = "%Q$(touch M) %N;x"
        try box.file("A/" + hostile)
        let (plugin, bench) = bench()
        define(plugin, "em_inner", "echo")
        define(plugin, "em_words", "tool", "/L=%A1 [%A]")
        define(plugin, "em_outer", "em_inner", "%N")
        define(plugin, "em_outer2", "em_words", "-v %N")
        bench.left.moveCursor(toName: hostile)
        bench.commands.perform("em_outer")
        bench.commands.perform("em_outer2")
        // The name is neither read for placeholders again nor left without its quotes.
        #expect(plugin.launched == ["echo \"%Q\\$(touch M) %N;x\"", "tool /L=-v [-v \"%Q\\$(touch M) %N;x\"]"])
    }

    @Test func aLineThatCannotTakeANameSafelyIsNotRun() {
        let (plugin, bench) = bench()
        define(plugin, "em_tick", "echo", "`basename %N`")
        define(plugin, "em_ansi", "echo", "$'%N'")
        define(plugin, "em_here", "cat <<EOF", "%N")
        define(plugin, "em_fine", "echo", "\"$(basename %N)\"")
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
        define(plugin, "em_list", "cat", "%L")
        bench.commands.perform(.selectAll)
        bench.commands.perform("em_list")
        #expect(bench.interaction.log.last == "inform: “list” was not run" && plugin.launched.count == 1)
        #expect(!FileManager.default.fileExists(atPath: box.url("lists").path))
    }

    @Test func theMarkedNamesOfALongListAreGatheredInTheBackground() async {
        let memory = MemoryFileSystem()
        let count = CommandRunner.backgroundSelectionThreshold + 3
        for number in 0..<count { memory.addFile("/Big/f\(number) x.txt") }
        memory.addDirectory("/B")
        let plugin = ConfigurationPlugin(
            launchesApplications: false, background: .global(qos: .userInitiated), listFolder: box.url("lists-big"),
            settingsKeys: { [] })
        let bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin], fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/Big"), right: memory.url("/B"))
        define(plugin, "em_all", "tool", "%S")
        define(plugin, "em_cursor", "tool", "%N")
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

    @Test func theSelectionIsGatheredOnlyForATextThatAsksForIt() {
        #expect(ParameterExpander.usesSelection([.text("%S")]) && ParameterExpander.usesSelection([.text("a %P%s")]))
        #expect(
            ParameterExpander.usesSelection([.text("%L")]) && ParameterExpander.usesSelection([.text("%C1")])
                && ParameterExpander.usesSelection([.text("%UF")]))
        #expect(
            !ParameterExpander.usesSelection([.text("%P%N %T%M %%S %O.%E")])
                && !ParameterExpander.usesSelection([.value("%S")]))
    }

    @Test func anApplicationPathWithASpaceIsOneWord() throws {
        let app = try box.folder("Apps/My App.app")
        let line: [ExpandedPiece] = [.text("\"\(app.path)\" --flag "), .value("a b")]
        let opened = try #require(CommandRunner.applicationLine(for: line))
        #expect(opened == [.text("/usr/bin/open -a "), .value(app.path), .text(" --flag "), .value("a b")])
        #expect(ShellLine.display(opened) == "/usr/bin/open -a \"\(app.path)\" --flag \"a b\"")
        // A line that is no application stays as it is.
        #expect(CommandRunner.applicationLine(for: [.text("ls -l")]) == nil)
        #expect(CommandRunner.applicationLine(for: [.text("\"\(box.url("Apps/None.app").path)\" x")]) == nil)
        #expect(ShellWords.firstWord(of: [.text("  \"a b\"c d e")]).word == [.text("\"a b\"c")])
        #expect(
            ShellWords.unquoted(ShellWords.firstWord(of: [.text("pre"), .value("x y"), .text("post rest")]).word)
                == "prex ypost")
    }

    @Test func listFilesOfARunThatQuitsAreKeptWhileAProgramMayReadThem() throws {
        let made = bench()
        let runner = CommandRunner(
            kernel: made.bench.kernel, launchesApplications: false, background: nil, listFolder: box.url("lists2"))
        let folder = try box.folder("lists2")
        let old = try box.file("lists2/list-old.txt")
        let fresh = try box.file("lists2/list-new.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-CommandRunner.listGrace * 3)], ofItemAtPath: old.path)
        runner.removeListFilesNow()
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-CommandRunner.listGrace * 3)], ofItemAtPath: fresh.path)
        runner.removeListFilesNow()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

/// The runner with real programs: a login shell is started, as in the program.
@MainActor @Suite struct Review2ConfigALaunching {
    let box: Sandbox
    let plugin: ConfigurationPlugin
    let bench: TestBench

    init() throws {
        box = try Sandbox()
        try box.folder("A")
        try box.folder("B")
        plugin = ConfigurationPlugin(
            launchesApplications: true, background: nil, listFolder: box.url("lists"), settingsKeys: { [] })
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin], fileSystems: [LocalFileSystem()],
            left: box.url("A"), right: box.url("B"))
    }

    func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(90)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func aHostileFileNameReachesTheProgramAsItIsAndRunsNothing() async throws {
        // The names that ran `touch` before: a quote and a backtick that carry a combining mark.
        let names = ["a\"\u{301};touch PWNED1;\"\u{301}", "`\u{301};touch PWNED2;`\u{301}", "$(touch PWNED3);x", "-n"]
        for name in names { try box.file("A/" + name) }
        bench.left.reload()
        let center = plugin.center!
        let out = box.url("out.bin").path
        // The panel's folder is where the line runs: a marker would appear in it.
        center.save(
            UserCommand(
                name: "em_show", title: "",
                action: CommandAction(command: "printf '%s\\0'", parameters: "%N \"%P%N\" x%Ny > '\(out)'")))
        for name in names {
            try? FileManager.default.removeItem(atPath: out)
            bench.left.moveCursor(toName: name)
            bench.commands.perform("em_show")
            func written() -> Data { (try? Data(contentsOf: URL(fileURLWithPath: out))) ?? Data() }
            await wait { written().filter { $0 == 0 }.count == 3 }
            let words = String(decoding: written(), as: UTF8.self).split(
                separator: "\0", omittingEmptySubsequences: false
            ).dropLast().map(String.init)
            let guarded = name.hasPrefix("-") ? "./" + name : name
            let folder = bench.left.model.directory.path
            #expect(
                words.map { Array($0.utf8) }
                    == [guarded, folder + "/" + name, "x" + name + "y"].map { Array($0.utf8) },
                "\(name.debugDescription): \(words.map(\.debugDescription))")
        }
        let created = try FileManager.default.contentsOfDirectory(atPath: box.url("A").path).filter {
            $0.hasPrefix("PWNED")
        }
        #expect(created.isEmpty && bench.interaction.log.isEmpty)
    }

    @Test func aProgramTheShellDoesNotFindIsReported() async {
        plugin.center!.save(
            UserCommand(
                name: "em_missing", title: "",
                action: CommandAction(command: "afm-no-such-program-\(UUID().uuidString)")))
        bench.commands.perform("em_missing")
        await wait { bench.interaction.log.contains { $0.hasPrefix("inform:") } }
        #expect(bench.interaction.log.count == 1 && bench.interaction.log[0].contains("cannot be started"))
    }

    @Test func aChainStopsWhenItsProgramCouldNotBeStarted() async {
        var probes = 0
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) { probes += 1 }
        let center = plugin.center!
        center.save(
            UserCommand(
                name: "em_bad", title: "", action: CommandAction(command: "afm-no-such-program-\(UUID().uuidString)"))
        )
        center.save(UserCommand(name: "em_chain", title: "", action: CommandAction(command: "em_bad, cm_ConfigProbe")))
        center.save(UserCommand(name: "em_good", title: "", action: CommandAction(command: "true")))
        center.save(
            UserCommand(name: "em_chain2", title: "", action: CommandAction(command: "em_good, cm_ConfigProbe")))
        bench.commands.perform("em_chain")
        await wait { bench.interaction.log.contains { $0.contains("cannot be started") } }
        bench.commands.perform("em_chain2")
        await wait { probes == 1 }
        // Only the chain whose program ran went on.
        #expect(probes == 1 && !center.runner.isWaiting)
    }
}
