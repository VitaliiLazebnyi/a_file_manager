import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The parts of the configuration plugin that need neither a window nor a kernel.
@MainActor @Suite struct ConfigurationModels {
    // MARK: Preference pages

    @Test func aPreferencePageHoldsChangesUntilApply() {
        let settings = MemorySettings()
        var changes = 0
        let flag = Preference("demo.flag", "Flag", .flag(default: true))
        let text = Preference("demo.text", "Text", .text(default: "abc"))
        let choice = Preference("demo.choice", "Choice", .choice(["a", "b", "c"], default: 1))
        let model = PreferencePageModel(
            page: PreferencePage(title: "Demo", preferences: [flag, text, choice]) { changes += 1 }, settings: settings
        )
        #expect(
            model.value(of: flag) == .flag(true) && model.value(of: text) == .text("abc")
                && model.value(of: choice) == .index(1))
        #expect(!model.isChanged)

        model.set(.flag(false), for: flag)
        model.set(.text("xyz"), for: text)
        model.set(.index(2), for: choice)
        #expect(model.isChanged && changes == 0)
        #expect(settings.flag("demo.flag", default: true) && settings.data(forKey: "demo.text") == nil)

        model.commit()
        #expect(changes == 1 && !model.isChanged)
        #expect(
            !settings.flag("demo.flag", default: true) && settings.text("demo.text", default: "") == "xyz"
                && settings.index("demo.choice", default: 0) == 2)
        // Nothing changed: the plugin is not told again.
        model.commit()
        #expect(changes == 1)

        // Cancel drops what was not applied; a fresh model reads the stored values.
        model.set(.text("dropped"), for: text)
        model.discard()
        #expect(model.value(of: text) == .text("xyz") && !model.isChanged)
        let reopened = PreferencePageModel(page: model.page, settings: settings)
        #expect(reopened.value(of: flag) == .flag(false) && reopened.value(of: choice) == .index(2))
    }

    // MARK: Key bindings

    let keyCommands = [
        Command("copy", "Copy", [.f(5), .cmd("c")]), Command("pack", "Pack", [.f(5, .option), .f(5)]),
        Command("view", "View", [.f(3)]),
        Command("em_mine", "Mine")
    ]

    @Test func theKeyMapFollowsTheKernelsRules() {
        let defaults = KeyMap.resolve(keyCommands, overrides: [:])
        #expect(
            defaults["copy"] == [.f(5), .cmd("c")] && defaults["pack"] == [.f(5, .option)] && defaults["em_mine"] == nil
        )
        let overrides = ["view": ["f5", "nonsense+"], "pack": []]
        let resolved = KeyMap.resolve(keyCommands, overrides: overrides)
        #expect(resolved["view"] == [.f(5)] && resolved["copy"] == [.cmd("c")] && resolved["pack"] == [])
        // The same result as the kernel arrives at.
        let keys = KeyBindings()
        for command in keyCommands { command.defaultShortcuts.forEach { keys.bindDefault($0, to: command.id) } }
        keys.apply(overrides: overrides)
        for command in keyCommands { #expect(keys.shortcuts(for: command.id) == resolved[command.id] ?? []) }
    }

    @Test func aKeyInUseNamesItsCommandAndIsTakenOnlyWhenTheUserAgrees() {
        let ui = ScriptedInteraction()
        let editor = KeyBindingEditor(commands: keyCommands, overrides: [:])
        #expect(editor.owner(of: .f(5)) == "copy" && editor.owner(of: .f(9)) == nil)
        // Without an answer the question is cancelled and the key stays.
        #expect(!editor.assign(.f(5), to: "view", adding: false, asking: ui))
        #expect(ui.log == ["choose: F5 is already in use / It runs “Copy” (copy). Give it to this command instead?"])
        #expect(editor.shortcuts(for: "copy") == [.f(5), .cmd("c")] && !editor.isChanged)

        ui.choiceAnswers = [0]
        #expect(editor.assign(.f(5), to: "view", adding: true, asking: ui))
        #expect(editor.shortcuts(for: "view") == [.f(3), .f(5)] && editor.shortcuts(for: "copy") == [.cmd("c")])
        #expect(
            editor.overrides == ["view": ["f3", "f5"], "copy": ["cmd+c"]] && editor.isCustomized("view")
                && editor.isChanged)
        // A free key needs no question.
        #expect(
            editor.assign(Shortcut(.character("m"), [.control, .shift]), to: "em_mine", adding: false, asking: ui)
                && ui.log.count == 2)
        #expect(editor.owner(of: Shortcut(.character("m"), [.control, .shift])) == "em_mine")

        editor.reset("view")
        #expect(editor.shortcuts(for: "view") == [.f(3)] && !editor.isCustomized("view"))
        editor.resetAll()
        #expect(editor.shortcuts(for: "copy") == [.f(5), .cmd("c")] && !editor.isChanged)
    }

    @Test func committedKeysAreStoredAndApplyAtOnceAndAfterARestart() {
        let settings = MemorySettings()
        func freshKeys() -> KeyBindings {
            let keys = KeyBindings()
            for command in keyCommands { command.defaultShortcuts.forEach { keys.bindDefault($0, to: command.id) } }
            return keys
        }
        let live = freshKeys()
        let editor = KeyBindingEditor(commands: keyCommands, overrides: [:])
        editor.set([.f(5), .f(9)], for: "pack")
        editor.set([], for: "view")
        editor.commit(to: settings, keyBindings: live)
        #expect(
            settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) == [
                "pack": ["f5", "f9"], "copy": ["cmd+c"], "view": []
            ])
        let restarted = freshKeys()
        restarted.load(from: settings)
        for keys in [live, restarted] {
            #expect(
                keys.command(for: .f(5)) == "pack" && keys.command(for: .f(9)) == "pack"
                    && keys.command(for: .f(3)) == nil)
            #expect(keys.shortcuts(for: "copy") == [.cmd("c")] && keys.shortcuts(for: "pack") == [.f(5), .f(9)])
        }
        // Back to the defaults: the stored bindings go, the running program follows.
        let again = KeyBindingEditor(
            commands: keyCommands,
            overrides: settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) ?? [:])
        again.resetAll()
        again.commit(to: settings, keyBindings: live)
        #expect(settings.data(forKey: KeyBindings.settingsKey) == nil)
        #expect(
            live.command(for: .f(5)) == "copy" && live.shortcuts(for: "pack") == [.f(5, .option)]
                && live.command(for: .f(3)) == "view")
    }

    @Test func shortcutsAreWrittenReadAndRecognisedFromKeyPresses() {
        #expect(ShortcutText.display(Shortcut(.character("c"), [.command, .shift, .control, .option])) == "⌃⌥⇧⌘C")
        #expect(ShortcutText.display([.f(5, .shift), Shortcut(.returnKey), Shortcut(.keypadPlus)]) == "⇧F5, ↩, Num +")
        #expect(ShortcutText.parse("ctrl+shift+n") == Shortcut(.character("n"), [.control, .shift]))
        #expect(ShortcutText.parse("⌘⇧F7") == .f(7, [.command, .shift]) && ShortcutText.parse(" F9 ") == .f(9))
        #expect(
            ShortcutText.parse("⌥Space") == Shortcut(.space, .option) && ShortcutText.parse("") == nil
                && ShortcutText.parse("hello") == nil)
        // Key codes of named keys win over the characters; other keys are their character.
        #expect(ShortcutText.shortcut(keyCode: 96, characters: "\u{F708}", modifiers: .control) == .f(5, .control))
        #expect(ShortcutText.shortcut(keyCode: 36, characters: "\r", modifiers: []) == Shortcut(.returnKey))
        #expect(
            ShortcutText.shortcut(keyCode: 8, characters: "C", modifiers: [.command, .shift]) == .cmd("c", .shift))
        #expect(ShortcutText.shortcut(keyCode: 8, characters: "", modifiers: []) == nil)
    }

    @Test func theCommandListIsGroupedByMenuAndFiltered() {
        let registry = MenuRegistry()
        registry.add(["copy", "pack"], to: MenuSection(MenuID("Files", order: 1), order: 1))
        registry.add(["view"], to: MenuSection(MenuID("Show", order: 2), order: 1))
        let menus = registry.menus
        let keys = KeyMap.resolve(keyCommands, overrides: [:])
        let rows = CommandCatalog.rows(commands: keyCommands, menus: menus) { keys[$0] ?? [] }
        #expect(rows.map(\.category) == ["Files", "Files", "Show", CommandRow.userCategory])
        #expect(rows[0] == CommandRow(id: "copy", title: "Copy", keys: "F5, ⌘C", category: "Files"))
        #expect(CommandCatalog.categories(of: rows, menus: menus) == ["Files", "Show", CommandRow.userCategory])
        #expect(CommandCatalog.filter(rows, text: "PA").map(\.id) == ["pack"])
        #expect(CommandCatalog.filter(rows, text: "f5 co").map(\.id) == ["copy"])
        #expect(CommandCatalog.filter(rows, text: "", category: "Show").map(\.id) == ["view"])
        let sheet = CommandCatalog.shortcutSheet(rows, menus: menus)
        #expect(sheet.hasPrefix("Files\n    F5, ⌘C") && sheet.contains("Show\n    F3") && !sheet.contains("Mine"))
    }

    // MARK: Button bar

    @Test func theButtonBarIsEditedAsAListAndStoredOnCommit() {
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
                && editor.symbol(for: "other") == "square.dashed")
        // Nothing has left the editor yet.
        #expect(settings.data(forKey: ToolbarRegistry.settingsKey) == nil && redraws == 0)

        editor.commit()
        #expect(redraws == 1 && !editor.isChanged && store.symbols == ["em_mine": "star", "copy": "heart"])
        #expect(
            toolbar.layout(from: settings) == [
                .init(command: "copy", symbol: "heart"), .init(command: "move", symbol: "arrow.right"),
                .init(command: "em_mine", symbol: "star"), nil, .init(command: "find", symbol: "magnifyingglass")
            ])
        // Cancel after more edits shows the stored bar again; reset goes back to the proposal.
        editor.remove(at: 0)
        editor.discard()
        #expect(editor.items.count == 5 && !editor.isChanged)
        editor.resetToDefault()
        editor.commit()
        #expect(
            settings.data(forKey: ToolbarRegistry.settingsKey) == nil
                && toolbar.layout(from: settings).map { $0?.command } == ["copy", "move", nil, "find"])
    }

    // MARK: Command language

    @Test func aCommandFieldIsReadAsStepsOrAsOneLine() {
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
                ])
        #expect(steps("cd /tmp/x y") == [.changeDirectory("/tmp/x y")])
        #expect(steps("%TOOLS%/pack -a,b 100%") == [.external("/opt/tools/pack -a,b 100%")])
        #expect(steps("cm_SelectAll,ls -l") == [.external("cm_SelectAll,ls -l")])
        #expect(steps("cm_Nope 1") == [.unknown("cm_Nope")] && steps("  ").isEmpty)

        let location: (String) -> URL = { URL(fileURLWithPath: $0) }
        #expect(CommandLanguage.argument(from: " 2 ", location: location) == .index(2))
        #expect(
            CommandLanguage.argument(from: "\"/etc/my hosts\"", location: location)
                == .location(URL(fileURLWithPath: "/etc/my hosts")))
        #expect(CommandLanguage.argument(from: "/usr/bin/say hi", location: location) == .text("/usr/bin/say hi"))
        #expect(CommandLanguage.argument(from: "*.txt", location: location) == .text("*.txt"))
        #expect(CommandLanguage.argument(from: "", location: location) == CommandArgument.none)

        #expect(UserCommand.name(from: " Backup_1 ") == "em_Backup_1" && UserCommand.name(from: "EM_x") == "em_x")
        #expect(UserCommand.name(from: "two words") == nil && UserCommand.name(from: "em_") == nil)
    }

    // MARK: Settings as a file

    @Test func settingsSurviveExportAndImport() throws {
        let settings = MemorySettings()
        settings.set(true, forKey: "a.flag")
        settings.set("text with “quotes”", forKey: "a.text")
        settings.set(7, forKey: "a.number")
        settings.set(["cm_Copy": ["f9"]], forKey: KeyBindings.settingsKey)
        settings.set(
            [UserCommand(name: "em_x", title: "X", action: CommandAction(command: "ls", parameters: "%P"))],
            forKey: "a.commands")
        settings.set(Data([0xFF, 0x00, 0x01]) as Data?, forKey: "a.raw")
        let keys = ["a.flag", "a.text", "a.number", KeyBindings.settingsKey, "a.commands", "a.raw", "a.missing"]

        let archive = SettingsArchive.capture(from: settings, keys: keys)
        #expect(archive.values.count == 6)
        let file = try archive.encoded()
        let text = try #require(String(data: file, encoding: .utf8))
        #expect(
            text.contains("\"format\" : \"A File Manager settings\"") && text.contains("\"a.flag\" : true")
                && text.contains("\"f9\""))

        let target = MemorySettings()
        target.set("stale", forKey: "a.missing")
        target.set("kept", forKey: "unknown.key")
        try SettingsArchive(data: file).restore(into: target, replacing: keys)
        #expect(
            target.flag("a.flag", default: false) && target.text("a.text", default: "") == "text with “quotes”"
                && target.index("a.number", default: 0) == 7)
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
