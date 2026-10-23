import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Stored configuration read leniently.
@MainActor
@Suite
internal struct ConfigPlacesFixStore {
    /// A store over new settings that hold `json` as the user commands, and those settings.
    internal func store(_ json: String) -> (ConfigurationStore, MemorySettings) {
        let settings = MemorySettings()
        settings.set(Data(json.utf8) as Data?, forKey: "configuration.userCommands")
        return (ConfigurationStore(settings: settings), settings)
    }

    /// Unknown keys are ignored, missing ones take their defaults, and bad elements are dropped and reported once.
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

    /// Data that is no list at all is kept aside before a new list replaces it.
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

    /// The list is decoded once and read again only after `invalidate`.
    @Test
    internal func theDecodedListIsCachedUntilItIsReplaced() {
        let (store, settings) = store(#"[{"name":"em_a"}]"#)
        #expect(store.userCommands.map(\.name) == ["em_a"])
        settings.set(Data(#"[{"name":"em_b"}]"#.utf8) as Data?, forKey: "configuration.userCommands")
        #expect(store.userCommands.map(\.name) == ["em_a"])
        store.invalidate()
        #expect(store.userCommands.map(\.name) == ["em_b"])
    }

    /// An archive with a bad user command or bad key bindings is refused before anything is written.
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
