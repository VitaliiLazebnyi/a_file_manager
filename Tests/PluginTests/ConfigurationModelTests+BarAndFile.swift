import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The button bar editor, the command language and the settings file.
extension ConfigurationModelTests {
    // MARK: Button bar

    /// The button bar is edited as a list, stored on commit, and reset to the proposal.
    @Test
    internal func theButtonBarIsEditedAsAListAndStoredOnCommit() {
        let settings = MemorySettings()
        let toolbar = ToolbarRegistry()
        var redraws = 0
        toolbar.onChange = { redraws += 1 }
        toolbar.add("copy", symbol: "doc.on.doc", group: 1)
        toolbar.add("move", symbol: "arrow.right", group: 1)
        toolbar.add("find", symbol: "magnifyingglass", group: 2)
        let store = ConfigurationStore(settings: settings)
        let editor = ToolbarEditor(toolbar: toolbar, settings: settings, store: store)
        #expect(editor.items == ["copy", "move", nil, "find"] && editor.isDefault && !editor.isChanged)

        #expect(editor.insert("em_mine", after: 0) == 1)
        #expect(editor.insert(nil, after: nil) == 5)
        editor.remove(at: 5)
        #expect(editor.move(1, by: 1) == 2 && editor.move(0, by: -1) == 0)
        editor.setSymbol("star", for: "em_mine")
        editor.setSymbol("heart", for: "copy")
        #expect(editor.items == ["copy", "move", "em_mine", nil, "find"] && editor.isChanged && !editor.isDefault)
        #expect(
            editor.symbol(for: "copy") == "heart" && editor.symbol(for: "move") == "arrow.right"
                && editor.symbol(for: "other") == "square.dashed"
        )
        // Nothing has left the editor yet.
        #expect(settings.data(forKey: ToolbarRegistry.settingsKey) == nil && redraws == 0)

        editor.commit()
        #expect(redraws == 1 && !editor.isChanged && store.symbols == ["em_mine": "star", "copy": "heart"])
        #expect(
            toolbar.layout(from: settings) == [
                .init(command: "copy", symbol: "heart"), .init(command: "move", symbol: "arrow.right"),
                .init(command: "em_mine", symbol: "star"), nil, .init(command: "find", symbol: "magnifyingglass")
            ]
        )
        // Cancel after more edits shows the stored bar again; reset goes back to the proposal.
        editor.remove(at: 0)
        editor.discard()
        #expect(editor.items.count == 5 && !editor.isChanged)
        editor.resetToDefault()
        editor.commit()
        #expect(
            settings.data(forKey: ToolbarRegistry.settingsKey) == nil
                && toolbar.layout(from: settings).map { $0?.command } == ["copy", "move", nil, "find"]
        )
    }

    // MARK: Command language

    /// A command field is read as steps of internal commands or as one external command line.
    @Test
    internal func aCommandFieldIsReadAsStepsOrAsOneLine() {
        let known: [CommandID] = ["cm_SelectAll", "cm_Copy", "em_notepad", "cm_List"]
        let resolve: (String) -> CommandID? = { name in known.first { $0.rawValue.lowercased() == name.lowercased() } }
        func steps(_ text: String) -> [CommandStep] {
            CommandLanguage.steps(text, environment: ["TOOLS": "/opt/tools"], resolve: resolve)
        }

        #expect(steps("cm_selectall") == [.perform("cm_SelectAll", parameter: "")])
        #expect(
            steps("cd \"/a, b\",cm_SelectAll , cm_wait 500,em_notepad \"x,y\" z")
                == [
                    .changeDirectory("/a, b"), .perform("cm_SelectAll", parameter: ""), .wait(milliseconds: 500),
                    .perform("em_notepad", parameter: "\"x,y\" z")
                ]
        )
        #expect(steps("cd /tmp/x y") == [.changeDirectory("/tmp/x y")])
        #expect(steps("%TOOLS%/pack -a,b 100%") == [.external("/opt/tools/pack -a,b 100%")])
        #expect(steps("cm_SelectAll,ls -l") == [.external("cm_SelectAll,ls -l")])
        #expect(steps("cm_Nope 1") == [.unknown("cm_Nope")] && steps("  ").isEmpty)

        let location: (String) -> URL = { URL(fileURLWithPath: $0) }
        #expect(CommandLanguage.argument(from: " 2 ", location: location) == .index(2))
        #expect(
            CommandLanguage.argument(from: "\"/etc/my hosts\"", location: location)
                == .location(URL(fileURLWithPath: "/etc/my hosts"))
        )
        #expect(CommandLanguage.argument(from: "/usr/bin/say hi", location: location) == .text("/usr/bin/say hi"))
        #expect(CommandLanguage.argument(from: "*.txt", location: location) == .text("*.txt"))
        #expect(CommandLanguage.argument(from: "", location: location) == CommandArgument.nothing)

        #expect(UserCommand.name(from: " Backup_1 ") == "em_Backup_1" && UserCommand.name(from: "EM_x") == "em_x")
        #expect(UserCommand.name(from: "two words") == nil && UserCommand.name(from: "em_") == nil)
    }

    // MARK: Settings as a file

    /// Settings written to a file and read back are the same; a file of another format is refused.
    @Test
    internal func settingsSurviveExportAndImport() throws {
        let settings = MemorySettings()
        settings.set(true, forKey: "a.flag")
        settings.set("text with “quotes”", forKey: "a.text")
        settings.set(7, forKey: "a.number")
        settings.set(["cm_Copy": ["f9"]], forKey: KeyBindings.settingsKey)
        settings.set(
            [UserCommand(name: "em_x", title: "X", action: CommandAction(command: "ls", parameters: "%P"))],
            forKey: "a.commands"
        )
        settings.set(Data([0xFF, 0x00, 0x01]) as Data?, forKey: "a.raw")
        let keys = ["a.flag", "a.text", "a.number", KeyBindings.settingsKey, "a.commands", "a.raw", "a.missing"]

        let archive = SettingsArchive.capture(from: settings, keys: keys)
        #expect(archive.values.count == 6)
        let file = try archive.encoded()
        let text = try #require(String(data: file, encoding: .utf8))
        #expect(
            text.contains("\"format\" : \"A File Manager settings\"") && text.contains("\"a.flag\" : true")
                && text.contains("\"f9\"")
        )

        let target = MemorySettings()
        target.set("stale", forKey: "a.missing")
        target.set("kept", forKey: "unknown.key")
        try SettingsArchive(data: file).restore(into: target, replacing: keys)
        #expect(
            target.flag("a.flag", default: false) && target.text("a.text", default: "") == "text with “quotes”"
                && target.index("a.number", default: 0) == 7
        )
        #expect(target.value([String: [String]].self, forKey: KeyBindings.settingsKey) == ["cm_Copy": ["f9"]])
        #expect(target.value([UserCommand].self, forKey: "a.commands")?.first?.action.parameters == "%P")
        #expect(target.data(forKey: "a.raw") == Data([0xFF, 0x00, 0x01]))
        // A known key the file lacks is removed; a key nobody knows is left alone.
        #expect(target.data(forKey: "a.missing") == nil && target.text("unknown.key", default: "") == "kept")

        #expect(throws: SettingsArchive.ArchiveError.self) {
            try SettingsArchive(data: Data("{\"format\":\"other\"}".utf8))
        }
        #expect(throws: SettingsArchive.ArchiveError.self) { try SettingsArchive(data: Data("not json".utf8)) }
    }
}
