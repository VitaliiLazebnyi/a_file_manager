import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Settings files that are wrong, too large or hold connections, and what an export leaves out.
extension Review2ConfigASettingsTests {
    /// A file with a value of the wrong kind is refused as a whole; numbers out of range are limited.
    @Test
    internal func valuesOfTheWrongKindAreRefusedAndNumbersLimited() throws {
        settings.set("keep", forKey: "extra.key")
        interaction.formAnswers = Array(repeating: .accept, count: 20)
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
            #expect(interaction.log.last == "inform: The settings could not be imported", "\(bad)")
        }
        // A refused file changes nothing at all.
        #expect(settings.text("extra.key", default: "") == "keep" && interaction.forms.isEmpty)

        // The reproducer of the fuzzer: a visit counter of the largest number there is.
        let repro = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/misc/settings-import-frequent-count-overflow.json")
        if FileManager.default.fileExists(atPath: repro.path) {
            commands.perform("afm_ImportSettings", .location(repro))
            #expect(stored("places.history.frequent") == #"{"counts":{"":0,"0":1000000}}"#)
        }
        let numbers = try file(
            #""places.history.frequent": {"counts":{"a":9223372036854775807,"b":-5,"c":7}}, "#
                + #""extra.key": [1e300, -9223372036854775808, 12, 2.5, true]"#
        )
        commands.perform("afm_ImportSettings", .location(numbers))
        #expect(stored("places.history.frequent") == #"{"counts":{"a":1000000,"b":0,"c":7}}"#)
        #expect(stored("extra.key") == "[1000000000000,-1000000000000,12,2.5,true]")
        let label = interaction.forms.last?.first?.label ?? ""
        #expect(label.contains("numbers were out of range"))
    }

    /// A file that is too large, missing or no settings file is refused.
    @Test
    internal func aFileThatIsTooLargeOrNoSettingsFileIsRefused() throws {
        let large = box.url("large.json")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(CheckedSettings.fileLimit) + 1)
        try handle.close()
        commands.perform("afm_ImportSettings", .location(large))
        #expect(interaction.log == ["inform: The settings could not be imported"])
        #expect(throws: CheckedSettings.Problem.self) { try CheckedSettings.read(large) }
        try Data("{}".utf8).write(to: large)
        commands.perform("afm_ImportSettings", .location(large))
        commands.perform("afm_ImportSettings", .location(box.url("missing.json")))
        #expect(interaction.log.count == 3 && interaction.forms.isEmpty)
    }

    /// An imported connection that reuses the number of a stored one for another server gets a number of its own.
    @Test
    internal func anImportedConnectionNeverTakesOverAStoredPassword() throws {
        let id = "11111111-2222-3333-4444-555555555555"
        let mine =
            #"[{"host":"mine.example","id":"\#(id)","name":"n","user":"u"},"#
            + #"{"host":"two.example","id":"AAAAAAAA-2222-3333-4444-555555555555","name":"t","user":"u"}]"#
        settings.set(Data(mine.utf8) as Data?, forKey: "network.connections")
        // The file reuses the number of a stored connection for another server.
        let url = try file(
            #""network.connections": [{"id":"\#(id)","name":"n","host":"evil.example","user":"u"},"#
                + #"{"host":"two.example","id":"AAAAAAAA-2222-3333-4444-555555555555","name":"t","user":"u"}], "#
                + #""network.lastUsed": "\#(id)""#
        )
        interaction.formAnswers = [.values(["connections": .flag(true)])]
        commands.perform("afm_ImportSettings", .location(url))
        let data = try #require(settings.data(forKey: "network.connections"))
        let imported = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(imported.map { $0["host"] } == ["evil.example", "two.example"])
        // The changed one has a number of its own, so the keychain has nothing for it; the unchanged one keeps
        // its number.
        let fresh = try #require(imported[0]["id"])
        #expect(
            fresh != id && UUID(uuidString: fresh) != nil && imported[1]["id"] == "AAAAAAAA-2222-3333-4444-555555555555"
        )
        #expect(stored("network.lastUsed") == "\"\(fresh)\"")
    }

    /// An export is readable by the user alone and leaves histories, connections and unreadable data out unless asked.
    @Test
    internal func anExportIsForTheUserAloneAndLeavesPrivateThingsOut() throws {
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
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        )
        #expect(mode == 0o600)
        #expect(try SettingsArchive(data: Data(contentsOf: url)).values.keys.sorted() == ["extra.key"])
        #expect(interaction.log == ["inform: The settings were exported"])
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("secret"))
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: box.root.path).contains { $0.hasSuffix(".tmp") }
        )

        // Asked for, the histories and the connections are in it; the copies of unreadable data never are.
        center.exportSettings(
            to: url,
            options: SettingsExportOptions(includesHistory: true, includesConnections: true),
            tellsWhatIsIncluded: true
        )
        #expect(
            try SettingsArchive(data: Data(contentsOf: url)).values.keys.sorted() == [
                "extra.key", "network.connections", "systemTools.history"
            ]
        )
        // What an export leaves out is not removed by importing it.
        commands.perform("afm_ExportSettings", .location(url))
        settings.set("other", forKey: "extra.key")
        interaction.formAnswers = [.accept]
        commands.perform("afm_ImportSettings", .location(url))
        #expect(
            settings.text("extra.key", default: "") == "value" && settings.data(forKey: "systemTools.history") != nil
                && settings.data(forKey: "network.connections") != nil
        )

        // The export dialog offers both, switched off.
        interaction.formAnswers = [.values(["history": .flag(true)])]
        #expect(center.askExportOptions() == SettingsExportOptions(includesHistory: true, includesConnections: false))
        #expect(center.askExportOptions() == nil)
        let description = SettingsExportOptions().description(count: 3)
        #expect(description.contains("Left out: typed command lines") && description.contains("saved connections"))
    }

    /// Stored lists are bounded, and the two latest damaged copies of the user commands are kept.
    @Test
    internal func storedListsAreBoundedAndUnreadableDataIsKeptTwice() async {
        let many = (0..<(ConfigurationStore.startMenuLimit + 100))
            .map { index in
                #"{"title":"t\#(index)","action":{"command":"ls"}}"#
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
