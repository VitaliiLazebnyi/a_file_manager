import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// What the configuration windows and commands share, and the plugin's commands, at the corners
/// the other suites leave. Nothing is put on screen: the stage records it.
@MainActor @Suite internal struct CovConfigCenter {
    private static let commandsKey = ConfigurationStore.owner + "." + ConfigurationStore.userCommandsKey
    private static let symbolsKey = ConfigurationStore.owner + "." + ConfigurationStore.symbolsKey

    /// A Start-menu position runs its entry; a separator, a position past the end and other names run nothing.
    @Test
    internal func startMenuPositionsFindTheirEntries() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let entry = StartMenuEntry(title: "Make", action: CommandAction(command: "make"))
        stage.center.store.startMenu = [.separator, entry]
        let find = try #require(stage.center.runner.startMenuEntry)
        #expect(find("cm_UserMenu2") == entry)
        #expect(find("cm_UserMenu1") == nil && find("cm_UserMenu3") == nil && find("cm_UserMenu0") == nil)
        #expect(find("cm_Other") == nil)
    }

    /// A damaged stored list is reported soon after the plugin starts, and the stored pictures are used.
    @Test
    internal func storedListsAndPicturesAreTakenAtTheStart() async throws {
        let stage = try CovConfigStage(stored: [
            Self.commandsKey: Data("[5]".utf8),
            Self.symbolsKey: Data(#"{"cm_Other":"star"}"#.utf8)
        ])
        defer { stage.close() }
        #expect(await AppWait.until { stage.ui.log.contains("inform: Some settings could not be read") })
        #expect(stage.bench.kernel.toolbar.symbol(for: "cm_Other") == "star")
    }

    /// Editing a user command keeps its name and keys unless they are changed; a cancelled form changes nothing.
    @Test
    internal func editingAUserCommandKeepsWhatIsNotChanged() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let command = UserCommand(name: "em_tool", title: "Tool", action: CommandAction(command: "ls"))
        stage.center.save(command)
        #expect(stage.center.setShortcut("ctrl+shift+t", for: command.id))
        stage.ui.formAnswers = [.cancel, .values(["title": .text("Better tool")])]
        #expect(stage.center.editUserCommand(command) == nil)
        let edited = try #require(stage.center.editUserCommand(command))
        #expect(edited.name == "em_tool" && edited.title == "Better tool")
        #expect(stage.ui.log.filter { $0 == "form: Edit User Command" }.count == 2)
        #expect(stage.bench.kernel.keyBindings.shortcuts(for: command.id).map(\.notation) == ["ctrl+shift+t"])
    }

    /// The dialog of a Start-menu entry: cancelled, without a title, with a shortcut that is none, and with one.
    @Test
    internal func theStartMenuEntryDialog() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let row = StartMenuDraft.Row(entry: StartMenuEntry(title: "Old", action: CommandAction(command: "x")))
        stage.ui.formAnswers = [
            .cancel,
            .values(["title": .text("  ")]),
            .values(["shortcut": .text("not a key!")]),
            .values(["shortcut": .text("f7")])
        ]
        #expect(stage.center.editStartMenuRow(row) == nil)
        #expect(stage.center.editStartMenuRow(row) == nil)
        let unkeyed = try #require(stage.center.editStartMenuRow(row))
        #expect(unkeyed.shortcut.isEmpty && unkeyed.entry.title == "Old")
        #expect(stage.ui.log.contains("inform: “not a key!” is not a shortcut"))
        #expect(try #require(stage.center.editStartMenuRow(row)).shortcut == "f7")
        #expect(stage.ui.log.filter { $0 == "form: Change Start Menu Item" }.count == 4)
    }

    /// An empty shortcut takes the keys away (and is nothing to do without keys); a text that is no shortcut says so.
    @Test
    internal func shortcutsWrittenAsText() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let id: CommandID = "cm_Other"
        stage.bench.commands.register(Command(id, "Other", [.f(9)])) {}
        #expect(stage.center.setShortcut("", for: "cm_Nothing"))
        #expect(stage.center.setShortcut("  ", for: id))
        #expect(stage.bench.kernel.keyBindings.shortcuts(for: id).isEmpty)
        #expect(!stage.center.setShortcut("nonsense+", for: id))
        #expect(stage.ui.log.last == "inform: “nonsense+” is not a shortcut")
    }

    /// The Start menu of the menu bar follows an edited Start menu, with its keys.
    @Test
    internal func theMenuBarFollowsTheStartMenu() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let bar = NSMenu()
        let start = NSMenu(title: MenuID.start.title)
        let fixed = NSMenuItem(title: "Change Start Menu…", action: nil, keyEquivalent: "")
        fixed.representedObject = ConfigurationPlugin.changeStartMenu.rawValue
        start.addItem(fixed)
        let startItem = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        startItem.submenu = start
        bar.addItem(startItem)
        stage.mainMenu = bar
        var draft = StartMenuDraft()
        draft.rows = [
            StartMenuDraft.Row(
                entry: StartMenuEntry(title: "&Build", action: CommandAction(command: "make")),
                shortcut: "ctrl+b"
            )
        ]
        stage.center.commit(draft)
        #expect(start.items.map(\.title) == ["Build", "", "Change Start Menu…"])
        #expect(start.items.first?.keyEquivalent == "b" && start.items.first?.keyEquivalentModifierMask == .control)
    }

    /// An export that cannot be written says so.
    @Test
    internal func anExportThatCannotBeWrittenSaysSo() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        stage.center.exportSettings(to: stage.box.url("missing/settings.json"))
        #expect(stage.ui.log == ["inform: The settings could not be exported"])
    }

    /// Saving the position writes the frames of the windows that keep one.
    @Test
    internal func savingThePositionWritesTheFramesOfWindows() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let name = "CovConfig-\(UUID().uuidString)"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(name)
        defer {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
            window.close()
        }
        stage.windows = [window, NSWindow()]
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        #expect(stage.commands.perform(ConfigurationPlugin.savePosition))
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") != nil)
    }

    /// Every window command makes its window and hands it over to be shown; About asks for the panel.
    @Test
    internal func theWindowCommandsShowTheirWindows() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let ids: [CommandID] = [
            .configuration, ConfigurationPlugin.redefineHotkeys, ConfigurationPlugin.buttonBarConfig,
            ConfigurationPlugin.changeStartMenu, ConfigurationPlugin.commandBrowser, ConfigurationPlugin.userCommands,
            ConfigurationPlugin.keyboardHelp, ConfigurationPlugin.helpIndex, ConfigurationPlugin.about
        ]
        for id in ids { #expect(stage.commands.perform(id), "\(id)") }
        let titles = stage.presented.compactMap { $0.window?.title }
        #expect(titles.filter { $0 == "Options" }.count == 4)
        #expect(titles.filter { $0 == "Choose Command" }.count == 2)
        #expect(titles.contains("Keyboard Shortcuts") && titles.contains("What Is Where"))
        #expect(stage.aboutPanels == 1 && stage.presented.allSatisfy { $0.window?.isVisible == false })
    }

    /// Export without a file asks for the options and the file; giving up anywhere writes nothing.
    @Test
    internal func exportAsksForOptionsAndAFile() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let file = stage.box.url("export.json")
        let web = try #require(URL(string: "https://example.com/settings.json"))
        stage.commands.perform(ConfigurationPlugin.exportSettings, .location(web))
        stage.ui.formAnswers = [.cancel, .accept, .accept, .accept]
        stage.commands.perform(ConfigurationPlugin.exportSettings)
        stage.commands.perform(ConfigurationPlugin.exportSettings)
        stage.chosenFile = web
        stage.commands.perform(ConfigurationPlugin.exportSettings)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        stage.chosenFile = file
        stage.commands.perform(ConfigurationPlugin.exportSettings)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(
            stage.fileRequests.map(\.saving) == [true, true, true]
                && stage.fileRequests.allSatisfy { $0.product == "Test" }
        )
        #expect(!stage.ui.log.contains { $0.hasPrefix("inform:") })
    }

    /// Import without a file asks for one; none, or one not on this Mac's disks, imports nothing.
    @Test
    internal func importAsksForAFile() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        stage.commands.perform(ConfigurationPlugin.importSettings)
        stage.chosenFile = URL(string: "https://example.com/settings.json")
        stage.commands.perform(ConfigurationPlugin.importSettings)
        #expect(stage.fileRequests.map(\.saving) == [false, false] && stage.ui.log.isEmpty)
        let file = stage.box.url("same.json")
        stage.center.exportSettings(to: file)
        stage.chosenFile = file
        stage.commands.perform(ConfigurationPlugin.importSettings)
        #expect(stage.ui.log.last == "inform: Nothing to import")
    }

    /// A damaged list that is reported after its kernel is gone is not reported.
    @Test
    internal func aProblemReportedAfterTheKernelIsGoneIsDropped() async throws {
        weak var gone: Kernel?
        do {
            let stage = try CovConfigStage(stored: [Self.commandsKey: Data("[5]".utf8)])
            gone = stage.bench.kernel
            stage.close()
        }
        // The report comes from the run loop; a block queued after it shows it has been handed on.
        var later = false
        MainLoop.perform { later = true }
        #expect(await AppWait.until { later })
        #expect(gone == nil)
    }

    /// A renamed user command does not keep the keys of its old name.
    @Test
    internal func aRenamedUserCommandLeavesNoKeyBehind() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let old = UserCommand(name: "em_old", title: "Old", action: CommandAction(command: "ls"))
        stage.center.save(old)
        #expect(stage.center.setShortcut("ctrl+shift+o", for: old.id))
        stage.center.save(UserCommand(name: "em_new", title: "New", action: old.action), replacing: "em_old")
        #expect(stage.center.store.userCommands.map(\.name) == ["em_new"])
        let stored = KeyBindingEditor.storedOverrides(in: stage.bench.kernel)
        #expect(stored["em_old"] == nil)
    }

    /// The silent effects of a plugin that launches nothing do nothing and choose nothing.
    @Test
    internal func theSilentEffectsDoNothing() {
        let silent = ConfigurationEffects.silent
        let controller = NSWindowController(window: NSWindow())
        silent.present(controller)
        silent.beep()
        silent.runModal(NSWindow())
        silent.stopModal()
        silent.showAbout()
        silent.removeKeyMonitor(silent.monitorKeys { $0 } as Any)
        #expect(controller.window?.isVisible == false)
        #expect(silent.chooseSettingsFile(true, "Test") == nil && silent.mainMenu() == nil && silent.windows().isEmpty)
    }

    /// The plugin lists nothing it launched before it starts.
    @Test
    internal func aPluginThatDidNotStartLaunchedNothing() {
        #expect(ConfigurationPlugin().launched.isEmpty)
    }

    /// Without a list of keys the plugin asks its store: another store than the program's
    /// preferences lists none; of a preferences domain the keys of JSON values count.
    @Test
    internal func theKeysOfTheStoreAreListedForThePreferencesAlone() throws {
        let stage = try CovConfigStage(settingsKeys: nil)
        defer { stage.close() }
        #expect(!stage.center.settingsKeys().contains("extra.key"))
        #expect(ConfigurationPlugin.storedKeys(of: MemorySettings()).isEmpty)
        let values: [String: Any] = [
            "b.json": Data(" [1]".utf8), "a.json": Data("{}".utf8), "text": Data("plain".utf8),
            "blank": Data("   ".utf8), "number": 5
        ]
        #expect(ConfigurationPlugin.storedKeys(in: values) == ["a.json", "b.json"])
    }
}
