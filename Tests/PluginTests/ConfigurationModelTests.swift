import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The parts of the configuration plugin that need neither a window nor a kernel.
@MainActor
@Suite
internal struct ConfigurationModelTests {
    /// Commands with default keys (F5 twice, once with Option), and a user command without one.
    internal let keyCommands = [
        Command("copy", "Copy", [.f(5), .cmd("c")]), Command("pack", "Pack", [.f(5, .option), .f(5)]),
        Command("view", "View", [.f(3)]),
        Command("em_mine", "Mine")
    ]

    // MARK: Preference pages

    /// A preference page keeps its changes until they are applied; Cancel drops them.
    @Test
    internal func aPreferencePageHoldsChangesUntilApply() {
        let settings = MemorySettings()
        var changes = 0
        let flag = Preference("demo.flag", "Flag", .flag(default: true))
        let text = Preference("demo.text", "Text", .text(default: "abc"))
        let choice = Preference("demo.choice", "Choice", .choice(["a", "b", "c"], default: 1))
        let model = PreferencePageModel(
            page: PreferencePage(title: "Demo", preferences: [flag, text, choice]) { changes += 1 },
            settings: settings
        )
        #expect(
            model.value(of: flag) == .flag(true) && model.value(of: text) == .text("abc")
                && model.value(of: choice) == .index(1)
        )
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
                && settings.index("demo.choice", default: 0) == 2
        )
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

    /// The key map resolves defaults and overrides the way the kernel's key bindings do.
    @Test
    internal func theKeyMapFollowsTheKernelsRules() {
        let defaults = KeyMap.resolve(keyCommands, overrides: [:])
        #expect(
            defaults["copy"] == [.f(5), .cmd("c")] && defaults["pack"] == [.f(5, .option)] && defaults["em_mine"] == nil
        )
        let overrides = ["view": ["f5", "nonsense+"], "pack": []]
        let resolved = KeyMap.resolve(keyCommands, overrides: overrides)
        #expect(resolved["view"] == [.f(5)] && resolved["copy"] == [.cmd("c")] && resolved["pack"]?.isEmpty == true)
        // The same result as the kernel arrives at.
        let keys = KeyBindings()
        bindDefaults(of: keyCommands, in: keys)
        keys.apply(overrides: overrides)
        for command in keyCommands { #expect(keys.shortcuts(for: command.id) == resolved[command.id] ?? []) }
    }

    /// A key in use names its command and moves to another command only when the user agrees.
    @Test
    internal func aKeyInUseNamesItsCommandAndIsTakenOnlyWhenTheUserAgrees() {
        let interaction = ScriptedInteraction()
        let editor = KeyBindingEditor(commands: keyCommands, overrides: [:])
        #expect(editor.owner(of: .f(5)) == "copy" && editor.owner(of: .f(9)) == nil)
        // Without an answer the question is cancelled and the key stays.
        #expect(!editor.assign(.f(5), to: "view", adding: false, asking: interaction))
        #expect(
            interaction.log == [
                "choose: F5 is already in use / It runs “Copy” (copy). Give it to this command instead?"
            ]
        )
        #expect(editor.shortcuts(for: "copy") == [.f(5), .cmd("c")] && !editor.isChanged)

        interaction.choiceAnswers = [0]
        #expect(editor.assign(.f(5), to: "view", adding: true, asking: interaction))
        #expect(editor.shortcuts(for: "view") == [.f(3), .f(5)] && editor.shortcuts(for: "copy") == [.cmd("c")])
        #expect(
            editor.overrides == ["view": ["f3", "f5"], "copy": ["cmd+c"]] && editor.isCustomized("view")
                && editor.isChanged
        )
        // A free key needs no question.
        #expect(
            editor.assign(
                Shortcut(.character("m"), [.control, .shift]),
                to: "em_mine",
                adding: false,
                asking: interaction
            )
                && interaction.log.count == 2
        )
        #expect(editor.owner(of: Shortcut(.character("m"), [.control, .shift])) == "em_mine")

        editor.reset("view")
        #expect(editor.shortcuts(for: "view") == [.f(3)] && !editor.isCustomized("view"))
        editor.resetAll()
        #expect(editor.shortcuts(for: "copy") == [.f(5), .cmd("c")] && !editor.isChanged)
    }

    /// Committed keys are stored and apply at once and after a restart; a reset removes them again.
    @Test
    internal func committedKeysAreStoredAndApplyAtOnceAndAfterARestart() {
        let settings = MemorySettings()
        func freshKeys() -> KeyBindings {
            let keys = KeyBindings()
            bindDefaults(of: keyCommands, in: keys)
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
            ]
        )
        let restarted = freshKeys()
        restarted.load(from: settings)
        for keys in [live, restarted] {
            #expect(
                keys.command(for: .f(5)) == "pack" && keys.command(for: .f(9)) == "pack"
                    && keys.command(for: .f(3)) == nil
            )
            #expect(keys.shortcuts(for: "copy") == [.cmd("c")] && keys.shortcuts(for: "pack") == [.f(5), .f(9)])
        }
        // Back to the defaults: the stored bindings go, the running program follows.
        let again = KeyBindingEditor(
            commands: keyCommands,
            overrides: settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) ?? [:]
        )
        again.resetAll()
        again.commit(to: settings, keyBindings: live)
        #expect(settings.data(forKey: KeyBindings.settingsKey) == nil)
        #expect(
            live.command(for: .f(5)) == "copy" && live.shortcuts(for: "pack") == [.f(5, .option)]
                && live.command(for: .f(3)) == "view"
        )
    }

    /// Shortcuts are written as symbols, read from text and recognised from key presses.
    @Test
    internal func shortcutsAreWrittenReadAndRecognisedFromKeyPresses() {
        #expect(ShortcutText.display(Shortcut(.character("c"), [.command, .shift, .control, .option])) == "⌃⌥⇧⌘C")
        #expect(ShortcutText.display([.f(5, .shift), Shortcut(.returnKey), Shortcut(.keypadPlus)]) == "⇧F5, ↩, Num +")
        #expect(ShortcutText.parse("ctrl+shift+n") == Shortcut(.character("n"), [.control, .shift]))
        #expect(ShortcutText.parse("⌘⇧F7") == .f(7, [.command, .shift]) && ShortcutText.parse(" F9 ") == .f(9))
        #expect(
            ShortcutText.parse("⌥Space") == Shortcut(.space, .option) && ShortcutText.parse("") == nil
                && ShortcutText.parse("hello") == nil
        )
        // Key codes of named keys win over the characters; other keys are their character.
        #expect(ShortcutText.shortcut(keyCode: 96, characters: "\u{F708}", modifiers: .control) == .f(5, .control))
        #expect(ShortcutText.shortcut(keyCode: 36, characters: "\r", modifiers: []) == Shortcut(.returnKey))
        #expect(
            ShortcutText.shortcut(keyCode: 8, characters: "C", modifiers: [.command, .shift]) == .cmd("c", .shift)
        )
        #expect(ShortcutText.shortcut(keyCode: 8, characters: "", modifiers: []) == nil)
    }

    /// The command list is grouped by menu, filtered by text and category, and printed as a sheet.
    @Test
    internal func theCommandListIsGroupedByMenuAndFiltered() {
        let registry = MenuRegistry()
        registry.add(["copy", "pack"], to: MenuSection(MenuID("Files", order: 1), order: 1))
        registry.add(["view"], to: MenuSection(MenuID("Show", order: 2), order: 1))
        let menus = registry.menus
        let keys = KeyMap.resolve(keyCommands, overrides: [:])
        let rows = CommandCatalog.rows(commands: keyCommands, menus: menus) { keys[$0] ?? [] }
        #expect(rows.map(\.category) == ["Files", "Files", "Show", CommandRow.userCategory])
        #expect(rows[0] == CommandRow(id: "copy", title: "Copy", keys: "F5, ⌘C", category: "Files"))
        #expect(CommandCatalog.categories(of: rows, menus: menus) == ["Files", "Show", CommandRow.userCategory])
        #expect(CommandCatalog.filter(rows, text: "PA", category: nil).map(\.id) == ["pack"])
        #expect(CommandCatalog.filter(rows, text: "f5 co", category: nil).map(\.id) == ["copy"])
        #expect(CommandCatalog.filter(rows, text: "", category: "Show").map(\.id) == ["view"])
        let sheet = CommandCatalog.shortcutSheet(rows, menus: menus)
        #expect(sheet.hasPrefix("Files\n    F5, ⌘C") && sheet.contains("Show\n    F3") && !sheet.contains("Mine"))
    }

    /// Binds the default keys of `commands` in `keys`, as the kernel does at the start.
    internal func bindDefaults(of commands: [Command], in keys: KeyBindings) {
        for command in commands {
            for shortcut in command.defaultShortcuts {
                keys.bindDefault(shortcut, to: command.id)
            }
        }
    }
}
