import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Hostile file names against the shell that runs a command line: the argv the shell builds
/// must be exactly the names, in every quoting context.
@Suite
internal struct ConfigPlacesFixExpansion {
    internal static let hostile = [
        "x'; touch pwned; '.txt", "a\"b$HOME`id`\\c.txt", "two words.txt", "line\nbreak.txt", "-rf", "!bang.txt",
        "$(id)"
    ]

    internal func context(name: String?) -> ExpansionContext {
        ExpansionContext(
            left: PanelSnapshot(path: "/tmp/A dir/", cursorName: name, selection: []),
            right: PanelSnapshot(path: "/B/", cursorName: nil),
            environment: ["EVIL": "e'v\"il $x `y`", "PLAIN": "/Users/me"],
            listFolder: URL(fileURLWithPath: "/tmp/lists"),
            listName: "t"
        )
    }

    /// The words /bin/zsh makes of `printf '%s\n' <line>`, separated by NUL for printing.
    internal func argv(_ line: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "cd /tmp && printf '%s\\0' " + line]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast()
            .map(String.init)
    }

    internal func expand(_ text: String, name: String?) -> ExpandedParameters {
        ParameterExpander(context: context(name: name)).expand(text)
    }

    @Test
    internal func unquotedPlaceholderIsOneWord() throws {
        for name in Self.hostile {
            let expanded = expand("%N", name: name).text
            let words = try argv(expanded)
            #expect(words == [name.hasPrefix("-") ? "./" + name : name], "\(name) -> \(expanded)")
            let path = try argv(expand("%P%N", name: name).text)
            #expect(path == ["/tmp/A dir/" + name])
        }
    }

    @Test
    internal func insideDoubleQuotes() throws {
        for name in Self.hostile {
            let expanded = expand("\"%N\"", name: name).text
            #expect(try argv(expanded) == [name.hasPrefix("-") ? "./" + name : name], "\(name) -> \(expanded)")
            #expect(try argv(expand("\"x%Ny\"", name: name).text) == ["x" + name + "y"])
        }
    }

    @Test
    internal func insideSingleQuotes() throws {
        for name in Self.hostile {
            let expanded = expand("'%N'", name: name).text
            #expect(try argv(expanded) == [name.hasPrefix("-") ? "./" + name : name], "\(name) -> \(expanded)")
            #expect(try argv(expand("'<%P%N>'", name: name).text) == ["</tmp/A dir/" + name + ">"])
        }
        // A backslash and an escaped quote the user wrote do not confuse the tracking.
        #expect(try argv(expand("\\\" '%N'", name: "a'b").text) == ["\"", "a'b"])
        #expect(try argv(expand("\"it's %N\"", name: "a'b").text) == ["it's a'b"])
    }

    @Test
    internal func environmentValuesAreQuotedToo() throws {
        #expect(try argv(expand("%|EVIL|", name: nil).text) == ["e'v\"il $x `y`"])
        #expect(try argv(expand("'%|EVIL|'", name: nil).text) == ["e'v\"il $x `y`"])
        #expect(try argv(expand("\"%|EVIL|\"", name: nil).text) == ["e'v\"il $x `y`"])
        #expect(expand("%|PLAIN|/x", name: nil).text == "/Users/me/x")
        #expect(
            try argv(CommandLanguage.expandingEnvironment("a %EVIL% '%EVIL%' \"%EVIL%\"", ["EVIL": "e'v\"il $x `y`"]))
                == ["a", "e'v\"il $x `y`", "e'v\"il $x `y`", "e'v\"il $x `y`"]
        )
    }

    @Test
    internal func selectedNamesAreSeparateWords() throws {
        var context = context(name: nil)
        context.left.selection = ["-n", "b c", "d'e"]
        let text = ParameterExpander(context: context).expand("%S").text
        #expect(try argv(text) == ["./-n", "b c", "d'e"])
    }

    @Test
    internal func aMissingNameIsReported() {
        #expect(expand("rm -rf %P%N", name: nil).missingName)
        #expect(
            expand("echo %V", name: nil).missingName && expand("%O.%E", name: nil).missingName
                && expand("%M", name: "x").missingName
        )
        #expect(!expand("rm %P%N", name: "a").missingName && !expand("ls %P %S", name: nil).missingName)
    }
}

/// Stored configuration read leniently.
@MainActor
@Suite
internal struct ConfigPlacesFixStore {
    internal func store(_ json: String, in settings: MemorySettings = MemorySettings()) -> (
        ConfigurationStore, MemorySettings
    ) {
        settings.set(Data(json.utf8) as Data?, forKey: "configuration.userCommands")
        return (ConfigurationStore(settings: settings), settings)
    }

    @Test
    internal func missingAndUnknownKeysAndABadElement() async {
        let json = """
            [{"name":"em_a","title":"A","action":{"command":"ls"}},
             {"name":"em_b","future":{"x":1},"action":{"command":"ls","parameters":"p","startPath":"/","more":true}},
             {"title":"no name"}, 42, {"name":"em_c"}]
            """
        let (store, settings) = store(json)
        var told: [String] = []
        store.onProblem = { told.append($0) }
        let commands = store.userCommands
        #expect(commands.map(\.name) == ["em_a", "em_b", "em_c"])
        #expect(
            commands[0].action == CommandAction(command: "ls")
                && commands[1].action == CommandAction(command: "ls", parameters: "p", startPath: "/")
        )
        await Task.yield()
        // Two bad elements: the original is kept aside and the user told, before anything is saved over it.
        #expect(settings.data(forKey: "configuration.userCommands.unreadable") == Data(json.utf8))
        #expect(told.count == 1 && told[0].contains("2 of the stored user commands"))
        #expect(store.userCommands.count == 3 && told.count == 1)
    }

    @Test
    internal func unreadableDataIsKept() async {
        let (store, settings) = store("not json at all")
        var told: [String] = []
        store.onProblem = { told.append($0) }
        #expect(store.userCommands.isEmpty)
        store.userCommands = [UserCommand(name: "em_new", title: "")]
        await Task.yield()
        #expect(
            settings.data(forKey: "configuration.userCommands.unreadable") == Data("not json at all".utf8)
                && told.count == 1
        )
        #expect(store.userCommands.map(\.name) == ["em_new"])
    }

    @Test
    internal func theDecodedListIsCachedUntilItIsReplaced() {
        let (store, settings) = store(#"[{"name":"em_a"}]"#)
        #expect(store.userCommands.map(\.name) == ["em_a"])
        settings.set(Data(#"[{"name":"em_b"}]"#.utf8) as Data?, forKey: "configuration.userCommands")
        #expect(store.userCommands.map(\.name) == ["em_a"])
        store.invalidate()
        #expect(store.userCommands.map(\.name) == ["em_b"])
    }

    @Test
    internal func anImportIsCheckedBeforeItIsWritten() throws {
        var archive = SettingsArchive()
        archive.values["configuration.userCommands"] = Data(#"[{"name":"em_a"},{"nope":1}]"#.utf8)
        #expect(throws: SettingsArchive.ArchiveError.self) { try archive.validate(keyBindingsKey: "keyBindings") }
        archive.values["configuration.userCommands"] = Data(#"[{"name":"em_a"}]"#.utf8)
        archive.values["keyBindings"] = Data(#"{"cm_X":["f9"]}"#.utf8)
        try archive.validate(keyBindingsKey: "keyBindings")
        archive.values["keyBindings"] = Data(#"[1]"#.utf8)
        #expect(throws: SettingsArchive.ArchiveError.self) { try archive.validate(keyBindingsKey: "keyBindings") }
    }
}

/// The runner: names that are not there, real paths of virtual listings, key bindings of deleted commands.
@MainActor
@Suite
internal struct ConfigPlacesFixRunner {
    internal let box: Sandbox
    internal let settings = MemorySettings()
    internal let plugin: ConfigurationPlugin
    internal let bench: TestBench

    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt")
        try box.folder("B")
        plugin = ConfigurationPlugin(
            launchesApplications: false,
            background: nil,
            listFolder: box.url("lists"),
            settingsKeys: { [] }
        )
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
    }

    internal var center: ConfigurationCenter { plugin.center! }

    @Test
    internal func aCommandWithANameCodeDoesNotRunWithoutAName() {
        center.save(
            UserCommand(name: "em_rm", title: "", action: CommandAction(command: "rm -rf", parameters: "%P%N"))
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform("em_rm")
        #expect(plugin.launched.count == 1)
        // The cursor on [..]: nothing runs, the user is told.
        bench.left.model.cursor = 0
        if bench.left.model.cursorItem == nil {
            bench.commands.perform("em_rm")
            #expect(plugin.launched.count == 1 && bench.interaction.log.last == "inform: “rm” needs a file")
        }
    }

    @Test
    internal func aDeletedUserCommandLeavesNoKeyBehind() {
        center.save(UserCommand(name: "em_k", title: "", action: CommandAction(command: "ls")))
        #expect(center.setShortcut("ctrl+shift+k", for: CommandID("em_k")))
        #expect(settings.value([String: [String]].self, forKey: KeyBindings.settingsKey)?["em_k"] == ["ctrl+shift+k"])
        center.removeUserCommand(named: "em_k")
        #expect(settings.data(forKey: KeyBindings.settingsKey) == nil)
    }

    @Test
    internal func theKeyboardEditorKeepsBindingsStoredElsewhere() {
        let editor = KeyBindingEditor(kernel: bench.kernel)
        editor.set([Shortcut(.character("j"), [.control])], for: CommandID("cm_SelectAll"))
        // The Start menu stores a key while the Keyboard page has an edit pending.
        center.save(UserCommand(name: "em_other", title: "", action: CommandAction(command: "ls")))
        #expect(center.setShortcut("ctrl+shift+o", for: CommandID("em_other")))
        editor.rebase(kernel: bench.kernel)
        editor.commit(to: settings, keyBindings: bench.kernel.keyBindings)
        let stored = settings.value([String: [String]].self, forKey: KeyBindings.settingsKey)
        #expect(stored?["em_other"] == ["ctrl+shift+o"] && stored?["cm_SelectAll"] == ["ctrl+j"])
    }
}

/// Programs are started by the runner itself, not through the command line's job.
@MainActor
@Suite
internal struct ConfigPlacesFixLaunching {
    internal let box: Sandbox
    internal let plugin: ConfigurationPlugin
    internal let bench: TestBench

    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt")
        try box.folder("B")
        plugin = ConfigurationPlugin(
            launchesApplications: true,
            background: nil,
            listFolder: box.url("lists"),
            settingsKeys: { [] }
        )
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
    }

    /// Lets the main actor run, so what the runner hands back to the main thread arrives.
    internal func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test
    internal func aChainWaitsForTheProgramBeforeItsNextStep() async {
        let marker = box.url("marker").path
        let center = plugin.center!
        center.save(
            UserCommand(name: "em_build", title: "", action: CommandAction(command: "sleep 0.3; touch '\(marker)'"))
        )
        // The next step looks for the file the program writes: it must exist by then.
        var existed: Bool?
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) {
            existed = FileManager.default.fileExists(atPath: marker)
        }
        center.save(
            UserCommand(name: "em_chain", title: "", action: CommandAction(command: "em_build, cm_ConfigProbe"))
        )
        bench.commands.perform("em_chain")
        await wait { existed != nil }
        #expect(existed == true)
    }

    @Test
    internal func aLaunchIsNoJobAndNoHistoryEntry() async {
        let marker = box.url("marker2").path
        plugin.center!
            .save(
                UserCommand(name: "em_touch", title: "", action: CommandAction(command: "touch '\(marker)'"))
            )
        bench.commands.perform("em_touch")
        #expect(!bench.jobService.titles.contains { $0.hasPrefix("Running") })
        await wait { FileManager.default.fileExists(atPath: marker) }
        #expect(FileManager.default.fileExists(atPath: marker))
        #expect(bench.kernel.settings.data(forKey: "systemTools.history") == nil)
    }

    @Test
    internal func aLaunchThatCannotStartIsReported() async {
        plugin.center!
            .save(
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
