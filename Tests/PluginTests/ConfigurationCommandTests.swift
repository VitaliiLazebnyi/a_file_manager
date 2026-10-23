import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// User commands, the Start menu and the settings commands, driven through the kernel.
@MainActor
@Suite
internal struct ConfigurationCommandTests {
    /// The folders `A` (three files) and `B`, and the list folder.
    internal let box: Sandbox
    /// The settings of the program.
    internal let settings = MemorySettings()
    /// The plugin, which records what it would launch instead of launching it.
    internal let plugin: ConfigurationPlugin
    /// The program the plugin runs in, `A` on the left and `B` on the right.
    internal let bench: TestBench
    /// The plugin's configuration, there once the plugin has started.
    internal let center: ConfigurationCenter

    /// The lines the runner started itself (it does not use the command line's job).
    internal var launched: [String] { plugin.launched }
    /// The commands of the program.
    internal var commands: CommandRegistry { bench.commands }
    /// The answers to the plugin's questions, and what it asked.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The path of folder `A`.
    internal var folderA: String { box.url("A").path }

    /// The bench over the two folders, with the plugin started.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/my file.txt")
        try box.file("A/one.txt")
        try box.file("A/two.txt")
        try box.folder("B")
        plugin = Self.makePlugin(box)
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        center = try #require(plugin.center)
    }

    /// A plugin that launches nothing, keeps its lists in `box` and stores one key of its own (`extra.key`).
    internal static func makePlugin(_ box: Sandbox) -> ConfigurationPlugin {
        ConfigurationPlugin(launchesApplications: false, background: nil, listFolder: box.url("lists")) {
            ["extra.key"]
        }
    }

    /// Saves a user command `name` without a title that runs `action`.
    internal func define(_ name: String, _ action: CommandAction) {
        center.save(UserCommand(name: name, title: "", action: action))
    }

    // MARK: User commands

    /// A user command runs its program with the parameters expanded, in its start folder; a change applies at once.
    @Test
    internal func aUserCommandRunsAProgramWithExpandedParameters() {
        define("em_show", CommandAction(command: "echo -n", parameters: "%P%N %T"))
        #expect(commands[CommandID("em_show")]?.title == "show")
        bench.left.moveCursor(toName: "my file.txt")
        commands.perform("em_show")
        #expect(launched == ["echo -n \"\(folderA)/my file.txt\" \(box.url("B").path)/"])
        // The start path becomes the folder the line runs in.
        define("em_there", CommandAction(command: "ls", startPath: "/tmp/some where"))
        commands.perform("em_there")
        #expect(launched.last == "cd \"/tmp/some where\" && ls")
        // A change of the definition takes effect at once; a removed command is disabled.
        define("em_show", CommandAction(command: "open", parameters: "%N"))
        commands.perform("em_show")
        #expect(launched.last == "open \"my file.txt\"")
        center.removeUserCommand(named: "em_show")
        #expect(!commands.isEnabled("em_show") && commands.perform("em_show") == false && launched.count == 3)
    }

    /// Text after a user command's name reaches it: as its parameters, as its `%A` words, or appended.
    @Test
    internal func textAfterTheNameReachesTheCommand() {
        bench.left.moveCursor(toName: "one.txt")
        // Parameters field empty: the text is the parameters, placeholders and all.
        define("em_echo", CommandAction(command: "echo"))
        commands.perform("em_echo", .text("hi %N"))
        // Parameters with %A codes take the words; without such a code the text is appended.
        define("em_alias", CommandAction(command: "tool", parameters: "/L=%A1 /R=%A2"))
        commands.perform("em_alias", .text("left right"))
        define("em_fixed", CommandAction(command: "tool", parameters: "-v"))
        commands.perform("em_fixed", .text("more"))
        // A user command inside another one, with its own text.
        define("em_outer", CommandAction(command: "em_echo nested %E,em_fixed"))
        commands.perform("em_outer")
        #expect(
            launched == ["echo hi one.txt", "tool /L=left /R=right", "tool -v more", "echo nested txt", "tool -v"]
        )
    }

    /// A leading question mark shows the parameters to the user, who may change them or cancel.
    @Test
    internal func aQuestionMarkLetsTheUserChangeTheParameters() {
        bench.left.moveCursor(toName: "one.txt")
        center.save(UserCommand(name: "em_ask", title: "Ask", action: CommandAction(command: "run", parameters: "?%N")))
        interaction.promptAnswers = [.text("other.txt --flag"), .cancel]
        commands.perform("em_ask")
        commands.perform("em_ask")
        #expect(launched == ["run other.txt --flag"])
        // A name is shown in quotes, so that as typed text it can be nothing but a name.
        #expect(
            interaction.log == [
                "prompt: Parameters for “Ask”: [\"one.txt\"]", "prompt: Parameters for “Ask”: [\"one.txt\"]"
            ]
        )
    }

    /// The list file a command names is written before the command starts.
    @Test
    internal func theListFileExistsWhenTheCommandStarts() {
        define("em_list", CommandAction(command: "cat", parameters: "%L"))
        commands.perform(.selectAll)
        commands.perform("em_list")
        let line = launched.first ?? ""
        #expect(line.hasPrefix("cat " + box.url("lists").path + "/list-") && line.hasSuffix(".txt"))
        let written = try? String(contentsOfFile: String(line.dropFirst(4)), encoding: .utf8)
        #expect(written == "\(folderA)/my file.txt\n\(folderA)/one.txt\n\(folderA)/two.txt\n")
    }

    /// A user command may run the program's commands, chains of them and `cd`; an unknown one is reported.
    @Test
    internal func commandsOfTheProgramChainsAndCd() {
        // Names in any case; a chain runs in the written order.
        define("em_marks", CommandAction(command: "CM_selectall,cm_ExchangeSelection,cm_SpreadSelection"))
        interaction.promptAnswers = [.text("one.*")]
        commands.perform("em_marks")
        #expect(bench.left.model.selection == ["one.txt"])
        // One command takes its parameter from the Parameters field.
        define("em_go", CommandAction(command: "cd", parameters: "%P.."))
        define("em_swap", CommandAction(command: "cd \(box.url("B").path)", startPath: folderA))
        commands.perform("em_swap")
        #expect(
            bench.left.model.directory.lastPathComponent == "B" && bench.right.model.directory.lastPathComponent == "A"
        )
        // `cd` alone takes the folder from the Parameters field.
        commands.perform("em_go")
        #expect(bench.left.model.directory.path == box.root.path && launched.isEmpty)
        define("em_bad", CommandAction(command: "cm_DoesNotExist"))
        commands.perform("em_bad")
        #expect(interaction.log.last == "inform: Unknown command")
    }

    /// A user command that calls itself, directly or not, is stopped there.
    @Test
    internal func aUserCommandThatCallsItselfIsStopped() {
        define("em_a", CommandAction(command: "em_b"))
        define("em_b", CommandAction(command: "em_a,em_c"))
        define("em_c", CommandAction(command: "echo done"))
        commands.perform("em_a")
        // The call back into em_a is refused; the rest of the chain runs.
        #expect(interaction.log == ["inform: “a” calls itself"] && launched == ["echo done"])
        define("em_self", CommandAction(command: "em_self"))
        commands.perform("em_self")
        #expect(interaction.log.count == 2 && launched.count == 1)
    }

    /// The definition dialog stores the command, registers it and binds its key, also after a restart.
    @Test
    internal func theDefinitionDialogStoresRegistersAndBindsTheKey() {
        interaction.formAnswers = [
            .values([
                "name": .text("Backup"), "title": .text("Back Up Now"), "command": .text("rsync -a"),
                "parameters": .text("%P %T"),
                "shortcut": .text("ctrl+shift+b"), "symbol": .text("externaldrive")
            ])
        ]
        commands.perform("afm_NewUserCommand")
        let stored = center.store.userCommands
        #expect(
            stored == [
                UserCommand(
                    name: "em_Backup",
                    title: "Back Up Now",
                    action: CommandAction(command: "rsync -a", parameters: "%P %T"),
                    symbol: "externaldrive"
                )
            ]
        )
        #expect(commands[CommandID("em_Backup")]?.title == "Back Up Now")
        let key = Shortcut(.character("b"), [.control, .shift])
        #expect(bench.kernel.keyBindings.command(for: key) == "em_Backup")
        #expect(
            settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) == ["em_Backup": ["ctrl+shift+b"]]
        )
        #expect(bench.kernel.toolbar.symbol(for: "em_Backup") == "externaldrive")
        commands.perform("em_Backup")
        #expect(launched == ["rsync -a \(folderA)/ \(box.url("B").path)/"])

        // A name that cannot be used, a name that exists, a key that is taken and kept.
        interaction.formAnswers = [
            .values(["name": .text("two words")]), .values(["name": .text("em_Backup")]),
            .values(["name": .text("other"), "command": .text("ls"), "shortcut": .text("⌃⇧B")])
        ]
        for _ in 1...3 { commands.perform("afm_NewUserCommand") }
        #expect(center.store.userCommands.map(\.name) == ["em_Backup", "em_other"])
        #expect(
            bench.kernel.keyBindings.command(for: key) == "em_Backup"
                && interaction.log.contains { $0.hasPrefix("choose: ⌃⇧B is already in use") }
        )

        // The next start registers the stored commands with their keys.
        let restarted = TestBench(
            plugins: [NavigationPlugin(), Self.makePlugin(box)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        #expect(
            restarted.commands[CommandID("em_other")] != nil
                && restarted.kernel.keyBindings.command(for: key) == "em_Backup"
        )
        #expect(restarted.kernel.toolbar.symbol(for: "em_Backup") == "externaldrive")
    }
}
