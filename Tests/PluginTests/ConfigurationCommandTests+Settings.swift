import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The Start menu, the plugin's menus, the settings file and the windows.
extension ConfigurationCommandTests {
    // MARK: Start menu

    /// The Start menu runs its entries by position; its keys move with them and it is there after a restart.
    @Test
    internal func theStartMenuRunsItsEntriesByPosition() throws {
        #expect(commands[CommandID("cm_UserMenu10")] != nil && !commands.isEnabled("cm_UserMenu1"))
        interaction.formAnswers = [
            .values([
                "title": .text("List"), "command": .text("ls -l"), "parameters": .text("%N"), "shortcut": .text("f9")
            ])
        ]
        var draft = center.startMenuDraft()
        draft.insert(try #require(center.editStartMenuRow(nil, proposing: CommandAction(), title: "")), after: nil)
        draft.insert(StartMenuDraft.Row(entry: .separator), after: 0)
        draft.insert(
            StartMenuDraft.Row(
                entry: StartMenuEntry(title: "Mark All", action: CommandAction(command: "cm_SelectAll"))
            ),
            after: 1
        )
        center.commit(draft)
        #expect(center.store.startMenu.map(\.title) == ["List", "-", "Mark All"])
        #expect(center.startMenuSections() == [["cm_UserMenu1"], ["cm_UserMenu3"]])
        #expect(center.startMenuDraft() == draft && draft.rows[0].shortcut == "f9")
        #expect(bench.kernel.keyBindings.command(for: .f(9)) == "cm_UserMenu1")

        bench.left.moveCursor(toName: "two.txt")
        commands.perform("cm_UserMenu1")
        commands.perform("cm_UserMenu3")
        #expect(launched == ["ls -l two.txt"] && bench.left.model.selection.count == 3)
        #expect(!commands.isEnabled("cm_UserMenu2") && !commands.isEnabled("cm_UserMenu4"))

        // Reordering moves the key with its entry.
        draft.move(0, by: 1)
        center.commit(draft)
        #expect(
            bench.kernel.keyBindings.command(for: .f(9)) == "cm_UserMenu2"
                && bench.kernel.keyBindings.shortcuts(for: "cm_UserMenu1").isEmpty
        )
        commands.perform("cm_UserMenu2")
        #expect(launched.count == 2)

        // At the next start the entries are in the Start menu, above the editor's entry.
        let restarted = TestBench(
            plugins: [NavigationPlugin(), Self.makePlugin(box)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        let start = restarted.kernel.menus.menus.first { $0.title == "Start" }
        #expect(start?.items == ["cm_UserMenu2", "cm_UserMenu3", nil, "cm_ChangeStartMenu", "afm_StopUserCommands"])
        #expect(
            restarted.commands[CommandID("cm_UserMenu2")]?.title == "List"
                && restarted.kernel.keyBindings.command(for: .f(9)) == "cm_UserMenu2"
        )
    }

    // MARK: Registration and settings

    /// The plugin's menus hold its commands, and its keys clash with none.
    @Test
    internal func theMenusOfTheConfigurationPlugin() {
        let menus = Dictionary(uniqueKeysWithValues: bench.kernel.menus.menus.map { ($0.title, $0.items) })
        #expect(
            menus["Configuration"] == [
                "cm_Config", nil, "cm_Confirmation", "cm_ButtonConfig", "cm_CommandBrowser", "afm_UserCommands",
                "afm_NewUserCommand", nil, "cm_ConfigSavePos", "cm_ConfigSaveSettings", nil,
                "afm_ExportSettings", "afm_ImportSettings", "afm_ResetSettings"
            ]
        )
        #expect(
            menus["Start"] == ["cm_ChangeStartMenu", "afm_StopUserCommands"]
                && menus["Help"] == ["cm_HelpIndex", "cm_Keyboard", "cm_About"]
        )
        #expect(
            bench.kernel.keyBindings.command(for: .cmd(",")) == .configuration
                && bench.kernel.keyClashes.isEmpty
        )
        let all = bench.kernel.menus.menus.flatMap(\.items).compactMap(\.self)
        #expect(all.allSatisfy { commands[$0] != nil })
        #expect(center.keyboardHelp().contains("⌘,") && center.whatIsWhere().contains("English"))
    }

    /// Settings are exported to a file, reset after a question, and imported with what the user ticks.
    @Test
    internal func settingsAreExportedImportedAndReset() throws {
        define("em_keep", CommandAction(command: "ls"))
        settings.set(["cm_SelectAll": ["f9"]], forKey: KeyBindings.settingsKey)
        settings.set("value", forKey: "extra.key")
        var changes = 0
        bench.kernel.preferences.add(
            PreferencePage(title: "Demo", preferences: [Preference("demo.flag", "Flag", .flag(default: false))]) {
                changes += 1
            }
        )
        settings.set(true, forKey: "demo.flag")
        #expect(
            center.settingsKeys().contains("demo.flag") && center.settingsKeys().contains("extra.key")
                && center.settingsKeys().contains("configuration.userCommands")
        )

        let file = box.url("settings.json")
        commands.perform("afm_ExportSettings", .location(file))
        #expect(
            try SettingsArchive(data: Data(contentsOf: file)).values.keys.sorted()
                == ["configuration.userCommands", "demo.flag", "extra.key", "keyBindings"]
        )

        // Reset asks first; Cancel changes nothing.
        commands.perform("afm_ResetSettings")
        #expect(settings.flag("demo.flag", default: false) && changes == 0)
        interaction.choiceAnswers = [0]
        commands.perform("afm_ResetSettings")
        #expect(
            !settings.flag("demo.flag", default: false) && settings.data(forKey: "extra.key") == nil
                && center.store.userCommands.isEmpty
        )
        #expect(settings.data(forKey: KeyBindings.settingsKey) == nil && changes == 1 && !commands.isEnabled("em_keep"))
        #expect(bench.kernel.keyBindings.command(for: .f(9)) == nil)

        // An import shows what it holds; user commands and key bindings come in only when ticked.
        interaction.formAnswers = [.values(["commands": .flag(true), "keys": .flag(true)])]
        commands.perform("afm_ImportSettings", .location(file))
        #expect(
            settings.flag("demo.flag", default: false) && settings.text("extra.key", default: "") == "value"
                && changes == 2
        )
        #expect(center.store.userCommands.map(\.name) == ["em_keep"] && commands.isEnabled("em_keep"))
        // The imported key bindings are in force at once.
        #expect(
            bench.kernel.keyBindings.command(for: .f(9)) == .selectAll
                && interaction.log.last == "inform: The settings were imported"
        )

        try "{}".write(to: file, atomically: true, encoding: .utf8)
        commands.perform("afm_ImportSettings", .location(file))
        #expect(
            interaction.log.last == "inform: The settings could not be imported" && center.store.userCommands.count == 1
        )
    }

    /// The Options window and the command browser are built from the pages and commands registered.
    @Test
    internal func theWindowsAreBuiltFromWhatIsRegistered() {
        center.save(UserCommand(name: "em_mine", title: "Mine", action: CommandAction(command: "ls")))
        bench.kernel.preferences.add(
            PreferencePage(
                title: "Demo",
                preferences: [
                    Preference("demo.flag", "Flag", .flag(default: false)),
                    Preference("demo.text", "Text", .text(default: "x")),
                    Preference("demo.choice", "Choice", .choice(["a", "b"], default: 0))
                ]
            )
        )
        bench.kernel.preferences.add(PreferencePage(title: "Empty", preferences: []))
        let options = OptionsWindowController(center: center)
        // Pages of the other plugins come first, the dialog's own last.
        #expect(options.pageTitles.contains("Demo") && !options.pageTitles.contains("Empty"))
        #expect(options.pageTitles.suffix(4) == ["Keyboard", "Button Bar", "Start Menu", "Settings File"])
        for (section, title) in [
            (OptionsWindowController.Section.first, options.pageTitles.first ?? ""), (.keyboard, "Keyboard"),
            (.buttonBar, "Button Bar"),
            (.startMenu, "Start Menu"), (.settingsFile, "Settings File")
        ] {
            options.prepare(section)
            options.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(options.shownPage == title)
        }
        let browser = center.browser()
        browser.prepare(picking: false, category: nil)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(
            browser.rows.count == commands.all.count
                && browser.rows.contains { $0.id == "em_mine" && $0.title == "Mine" }
        )
        browser.prepare(picking: true, category: CommandRow.userCategory)
        #expect(browser.rows.map(\.id) == ["em_mine"])
        // A removed user command stays registered until the next start but is no longer offered.
        center.removeUserCommand(named: "em_mine")
        browser.prepare(picking: false, category: nil)
        #expect(!browser.rows.contains { $0.id == "em_mine" })
    }

    /// Save Settings writes the tabs of both panels.
    @Test
    internal func saveSettingsWritesThePanelsTabs() {
        commands.perform("cm_ConfigSaveSettings")
        let left = settings.value(PanelTabs.State.self, forKey: "left.tabs")
        #expect(left?.tabs.count == 1 && left == bench.left.tabs.state && settings.data(forKey: "right.tabs") != nil)
    }
}
