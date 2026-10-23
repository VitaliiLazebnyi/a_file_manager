import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The models behind the configuration windows, at the corners the other suites leave.
@MainActor
@Suite
internal struct CovConfigModels {
    /// A stored action without fields has empty ones.
    @Test
    internal func aStoredActionWithoutFieldsIsEmpty() throws {
        let action = try JSONDecoder().decode(CommandAction.self, from: Data("{}".utf8))
        #expect(action == CommandAction())
    }

    /// Every key has a name of its own, and the names read back as the keys.
    @Test
    internal func everyKeyIsWrittenAndReadByItsName() {
        for key in ShortcutText.namedKeys {
            let shortcut = Shortcut(key, .command)
            #expect(ShortcutText.parse(ShortcutText.display(shortcut)) == shortcut, "\(key)")
        }
        #expect(ShortcutText.display(Shortcut(.character("q"), [.control, .option, .shift])) == "⌃⌥⇧Q")
        #expect(ShortcutText.display(Shortcut.f(5, .shift)) == "⇧F5")
        #expect(Set(ShortcutText.namedKeys.map(\.macSymbol)).count == ShortcutText.namedKeys.count)
    }

    /// A key owned by a command that is not registered names that command by its name.
    @Test
    internal func aKeyOfAnUnknownCommandNamesItByItsName() {
        let editor = KeyBindingEditor(commands: [], overrides: ["em_gone": ["f9"]])
        let interaction = ScriptedInteraction()
        interaction.choiceAnswers = [1]
        #expect(!editor.assign(.f(9), to: "em_new", adding: false, asking: interaction))
        #expect(interaction.log.first?.contains("It runs “em_gone” (em_gone).") == true)
    }

    /// A page model shows what is stored for a preference that is not on its page.
    @Test
    internal func aPreferenceOfAnotherPageShowsWhatIsStored() {
        let settings = MemorySettings()
        let other = Preference("other.flag", "Other", .flag(default: true))
        let model = PreferencePageModel(
            page: PreferencePage(title: "Page", preferences: [Preference("page.flag", "Flag", .flag(default: false))]),
            settings: settings
        )
        #expect(model.value(of: other) == .flag(true))
    }

    /// The button-bar editor ignores rows that are not there, takes a picture away with an empty
    /// name, and stores nothing when nothing changed.
    @Test
    internal func theButtonBarEditorAtItsEdges() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let kernel = stage.bench.kernel
        let editor = ToolbarEditor(toolbar: kernel.toolbar, settings: stage.settings, store: stage.center.store)
        let before = editor.items
        editor.remove(at: before.count + 5)
        #expect(editor.items == before && !editor.isChanged)
        editor.commit()
        #expect(stage.settings.data(forKey: ToolbarRegistry.settingsKey) == nil)
        editor.setSymbol("star", for: .configuration)
        #expect(editor.symbol(for: .configuration) == "star")
        editor.setSymbol("", for: .configuration)
        #expect(editor.symbol(for: .configuration) == "gearshape" && editor.isChanged)
    }

    /// A Start-menu row is not moved past either end.
    @Test
    internal func aStartMenuRowStaysWithinTheList() {
        var draft = StartMenuDraft(rows: [StartMenuDraft.Row(entry: .separator)])
        #expect(draft.move(0, by: 1) == 0 && draft.move(3, by: -1) == 3)
    }

    /// A settings file with a damaged value says which one; a damaged Start menu is refused.
    @Test
    internal func aDamagedStartMenuIsRefusedByName() {
        var archive = SettingsArchive()
        let key = ConfigurationStore.owner + "." + ConfigurationStore.startMenuKey
        archive.values[key] = Data("[5]".utf8)
        let error = #expect(throws: SettingsArchive.ArchiveError.self) { try archive.validate(keyBindingsKey: "keys") }
        #expect(error?.errorDescription?.contains("“\(key)”") == true)
    }

    /// The failure of a program that cannot be started says why; a line that is too long says what to do.
    @Test
    internal func aFailedStartSaysWhy() {
        #expect(ChildProcess.Failure(code: E2BIG).message.contains("list file (%L)"))
        #expect(ChildProcess.Failure(code: ENOENT).message == String(cString: strerror(ENOENT)))
    }
}
