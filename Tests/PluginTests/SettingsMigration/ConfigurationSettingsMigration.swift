import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The key bindings, user commands, Start menu, button pictures and settings files written by
/// earlier versions load as they were meant, and are written again in the same shape.
@MainActor
@Suite
internal struct ConfigurationSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The user's key bindings as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `keyBindings`: command name to its keys in text form, the first the main key. Copy
        /// on Shift+F5 and Ctrl+C, Delete on F8 alone, a user command on Option+B.
        internal static let keyBindings = #"""
            {"cm_Copy":["shift+f5","ctrl+c"],"cm_Delete":["f8"],"em_backup":["opt+b"]}
            """#

        /// The user commands as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `configuration.userCommands`: `em_backup` copies the selected files to a disk, with a
        /// picture for the button bar.
        internal static let userCommands = #"""
            [{"name":"em_backup","title":"Back up","action":{"command":"rsync","parameters":"-a %P \/Volumes\/Backup",\#
            "startPath":"~"},"symbol":"externaldrive"}]
            """#

        /// User commands with a field this version does not know.
        ///
        /// What a later version could write: `hotkey` is ignored, the command loads.
        internal static let userCommandsMoreFields = #"""
            [{"name":"em_later","title":"Later","action":{"command":"cd ~","parameters":"","startPath":""},\#
            "symbol":"","hotkey":"opt+l"}]
            """#

        /// A user command and a Start menu entry with fields left out.
        ///
        /// What a version with fewer fields would have written: no `symbol`, an action without
        /// `parameters` and `startPath`, an entry without an action.
        internal static let userCommandsFewerFields = #"[{"name":"em_old","title":"Old","action":{"command":"cd ~"}}]"#

        /// See `userCommandsFewerFields`.
        internal static let startMenuFewerFields = #"[{"title":"Documents"}]"#

        /// The Start menu as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `configuration.startMenu`: "Terminal here" (T is its accelerator) and a separator.
        internal static let startMenu = #"""
            [{"title":"&Terminal here","action":{"command":"open","parameters":"-a Terminal %P","startPath":""}},\#
            {"title":"-","action":{"command":"","parameters":"","startPath":""}}]
            """#

        /// The pictures the user gave to commands, as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `configuration.symbols`: command name to a system symbol.
        internal static let symbols = #"{"cm_Copy":"doc.on.doc.fill"}"#

        /// A settings file as commit 16d647d (2026-10-14) exported it.
        ///
        /// Format "A File Manager settings", version 1: every value as the JSON it is stored as.
        /// Key bindings, the button bar, a tab, the hotlist, the colours by file type, the
        /// Lister's search options and a user command.
        internal static let archive = #"""
            {"format":"A File Manager settings","version":1,"settings":{\#
            "keyBindings":{"cm_Copy":["shift+f5"]},\#
            "toolbar.layout":["cm_Copy","","cm_Delete"],\#
            "left.tabs":{"tabs":[{"location":"file:\/\/\/Users\/me\/","sortKey":0,"descending":false,\#
            "showHidden":false}],"active":0},\#
            "places.hotlist":{"entries":[{"kind":"item","title":"Home","command":"cd ~","target":"","children":[]}],\#
            "hideCharacter":"?","hidesMarked":false},\#
            "panel.colorRules":"*.zip = purple;;*.app = green",\#
            "viewer.searchOptions":{"wholeWords":false,"caseSensitive":true,"backwards":false,"hex":false,\#
            "regex":false},\#
            "configuration.userCommands":[{"name":"em_backup","title":"Back up","action":{"command":"rsync",\#
            "parameters":"-a %P","startPath":""},"symbol":""}]}}
            """#

        /// The keys the archive holds, each with its value.
        internal static let archiveValues: [String: String] = [
            "keyBindings": #"{"cm_Copy":["shift+f5"]}"#,
            "toolbar.layout": #"["cm_Copy","","cm_Delete"]"#,
            "left.tabs": #"""
            {"tabs":[{"location":"file:\/\/\/Users\/me\/","sortKey":0,"descending":false,"showHidden":false}],\#
            "active":0}
            """#,
            "places.hotlist": #"""
            {"entries":[{"kind":"item","title":"Home","command":"cd ~","target":"","children":[]}],\#
            "hideCharacter":"?","hidesMarked":false}
            """#,
            "panel.colorRules": #""*.zip = purple;;*.app = green""#,
            "viewer.searchOptions": #"""
            {"wholeWords":false,"caseSensitive":true,"backwards":false,"hex":false,"regex":false}
            """#,
            "configuration.userCommands": #"""
            [{"name":"em_backup","title":"Back up","action":{"command":"rsync","parameters":"-a %P",\#
            "startPath":""},"symbol":""}]
            """#
        ]
    }

    /// A kernel without plugins on the settings: it reads the key bindings when it starts.
    private static func kernel(on settings: any SettingsStore) -> Kernel {
        let memory = MemoryFileSystem()
        return TestBench(
            plugins: [],
            fileSystems: [memory],
            left: memory.addDirectory("/A"),
            right: memory.addDirectory("/B"),
            settings: settings
        )
        .kernel
    }

    /// The configuration plugin on the settings, with a file system for the export and import.
    private static func configuration(
        on settings: any SettingsStore,
        in box: Sandbox
    ) throws -> (bench: TestBench, center: ConfigurationCenter) {
        let plugin = ConfigurationPlugin(launchesApplications: false, background: nil, listFolder: box.url("lists")) {
            ["places.hotlist", "panel.colorRules", "viewer.searchOptions"]
        }
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: try box.folder("A"),
            right: try box.folder("B"),
            settings: settings
        )
        return (bench, try #require(plugin.center))
    }

    /// The key bindings load: every key goes to its command, the first is the main key.
    @Test
    internal func theKeyBindingsLoad() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.keyBindings, forKey: KeyBindings.settingsKey, in: settings)
        let keys = Self.kernel(on: settings).keyBindings
        #expect(keys.shortcuts(for: .copy) == [.f(5, .shift), Shortcut(.character("c"), .control)])
        #expect(keys.command(for: .f(5, .shift)) == .copy && keys.command(for: .f(8)) == .delete)
        #expect(keys.shortcuts(for: .delete) == [.f(8)])
        #expect(keys.command(for: Shortcut(.character("b"), .option)) == "em_backup")
    }

    /// The key bindings editor stores them again in the shape they were read in.
    @Test
    internal func theKeyBindingsAreSavedInTheSameShape() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.keyBindings, forKey: KeyBindings.settingsKey, in: settings)
        let kernel = Self.kernel(on: settings)
        KeyBindingEditor(kernel: kernel).commit(to: settings, keyBindings: kernel.keyBindings)
        #expect(SettingsJSON.matches(settings.data(forKey: KeyBindings.settingsKey), Fixture.keyBindings))
    }

    /// The user commands, the Start menu and the pictures load with every field.
    @Test
    internal func theCommandsTheStartMenuAndThePicturesLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.userCommands, forKey: "configuration.userCommands", in: settings)
        SettingsJSON.store(Fixture.startMenu, forKey: "configuration.startMenu", in: settings)
        SettingsJSON.store(Fixture.symbols, forKey: "configuration.symbols", in: settings)
        let store = ConfigurationStore(settings: settings)
        let backup = try #require(store.userCommand(named: "em_backup"))
        #expect(backup.title == "Back up" && backup.caption == "Back up" && backup.symbol == "externaldrive")
        #expect(backup.action == CommandAction(command: "rsync", parameters: "-a %P /Volumes/Backup", startPath: "~"))
        #expect(store.startMenu.map(\.title) == ["&Terminal here", "-"])
        #expect(store.startMenu[0].action.parameters == "-a Terminal %P" && store.startMenu[1].isSeparator)
        #expect(store.symbols == ["cm_Copy": "doc.on.doc.fill"])
        #expect(settings.data(forKey: "configuration.userCommands.unreadable") == nil)
    }

    /// A field this version does not know is ignored; the command loads.
    @Test
    internal func aUserCommandWithMoreFieldsLoads() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.userCommandsMoreFields, forKey: "configuration.userCommands", in: settings)
        let store = ConfigurationStore(settings: settings)
        #expect(store.userCommands.map(\.name) == ["em_later"] && store.userCommands.first?.action.command == "cd ~")
        #expect(settings.data(forKey: "configuration.userCommands.unreadable") == nil)
    }

    /// Fields left out take their defaults, without a complaint.
    @Test
    internal func entriesWithFewerFieldsLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.userCommandsFewerFields, forKey: "configuration.userCommands", in: settings)
        SettingsJSON.store(Fixture.startMenuFewerFields, forKey: "configuration.startMenu", in: settings)
        let store = ConfigurationStore(settings: settings)
        let old = try #require(store.userCommands.first)
        #expect(store.userCommands.count == 1 && old.name == "em_old" && old.title == "Old" && old.symbol.isEmpty)
        #expect(old.action == CommandAction(command: "cd ~", parameters: "", startPath: ""))
        #expect(store.startMenu.map(\.title) == ["Documents"] && store.startMenu.first?.action == CommandAction())
        #expect(settings.data(forKey: "configuration.userCommands.unreadable") == nil)
        #expect(settings.data(forKey: "configuration.startMenu.unreadable") == nil)
    }

    /// The user commands, the Start menu and the pictures are stored again in the same shape.
    @Test
    internal func theCommandsTheStartMenuAndThePicturesAreSavedInTheSameShape() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.userCommands, forKey: "configuration.userCommands", in: settings)
        SettingsJSON.store(Fixture.startMenu, forKey: "configuration.startMenu", in: settings)
        SettingsJSON.store(Fixture.symbols, forKey: "configuration.symbols", in: settings)
        let store = ConfigurationStore(settings: settings)
        store.userCommands = store.userCommands
        store.startMenu = store.startMenu
        store.symbols = store.symbols
        #expect(SettingsJSON.matches(settings.data(forKey: "configuration.userCommands"), Fixture.userCommands))
        #expect(SettingsJSON.matches(settings.data(forKey: "configuration.startMenu"), Fixture.startMenu))
        #expect(SettingsJSON.matches(settings.data(forKey: "configuration.symbols"), Fixture.symbols))
    }

    /// A settings file is imported (with the parts that need a tick ticked), every value lands
    /// as it was in the file and is read by its owner; exported again, the file has the same
    /// content.
    @Test
    internal func aSettingsFileIsImportedAndExportedInTheSameShape() throws {
        let box = try Sandbox()
        let settings = MemorySettings()
        let (bench, _) = try Self.configuration(on: settings, in: box)
        let file = box.url("settings.json")
        try Data(Fixture.archive.utf8).write(to: file)
        bench.interaction.formAnswers = [
            .values(["keys": .flag(true), "commands": .flag(true), "hotlist": .flag(true)])
        ]
        bench.commands.perform("afm_ImportSettings", .location(file))
        #expect(bench.interaction.log.last == "inform: The settings were imported")
        for (key, value) in Fixture.archiveValues.sorted(by: { $0.key < $1.key }) {
            #expect(SettingsJSON.matches(settings.data(forKey: key), value), "\(key)")
        }
        // The key bindings take effect at the next start.
        #expect(Self.kernel(on: settings).keyBindings.command(for: .f(5, .shift)) == .copy)
        #expect(bench.kernel.toolbar.layout(from: settings).map { $0?.command } == [.copy, nil, .delete])
        #expect(ConfigurationStore(settings: settings).userCommand(named: "em_backup")?.action.command == "rsync")
        let exported = box.url("exported.json")
        bench.commands.perform("afm_ExportSettings", .location(exported))
        #expect(SettingsJSON.matches(try Data(contentsOf: exported), Fixture.archive))
    }
}
