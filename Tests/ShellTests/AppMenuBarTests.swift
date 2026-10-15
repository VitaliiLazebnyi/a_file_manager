import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The menu bar: the Mac's own menus around the plugins' ones, editing, and menus too long for the screen.
@MainActor
@Suite(.serialized)
internal struct AppMenuBarTests {
    /// The window's folders and stand-ins.
    private let fixture: AppFixture
    /// The plugin that brings the test's commands, a configuration dialog and a Help menu.
    private let extra = WindowTestPlugin()

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// The program menu, Edit, Window and Help are the Mac's; the plugins' menus stand between them.
    @Test
    internal func theMenuBarHasTheMacsOwnMenusAroundThePlugins() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let menu = app.shell.makeMainMenu()
        #expect(
            menu.items.map(\.title) == [
                "A File Manager", "Files", "Edit", "Mark", "Commands", "Show", "Configuration", "Window", "Help"
            ]
        )
        func titles(_ index: Int) -> [String] {
            menu.items[index].submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        }
        // Settings… runs the configuration command.
        #expect(
            titles(0) == [
                "About A File Manager", "-", "Settings…", "-", "Services", "-", "Hide A File Manager", "Hide Others",
                "Show All", "-", "Quit A File Manager"
            ]
        )
        let settingsItem = menu.items[0].submenu?.items[2]
        #expect(settingsItem?.keyEquivalent == "," && settingsItem?.keyEquivalentModifierMask == .command)
        #expect(app.shell.canShowSettings)
        app.shell.showSettings()
        #expect(extra.settingsShown == 1)
        // Text fields get the editing actions: Undo and Redo from the shell, the others from
        // the plugins' commands, which travel the same path.
        #expect(titles(2).starts(with: ["Undo", "Redo", "-"]))
        let actions = menu.items.flatMap { $0.submenu?.items ?? [] }.compactMap(\.action)
        for action in [
            #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
            #selector(NSResponder.selectAll(_:)), Selector(("undo:")), Selector(("redo:"))
        ] {
            #expect(actions.count { $0 == action } == 1)
        }
        // The Help menu of the plugins comes last and is the one the system knows as such.
        #expect(MenuBuilder.submenu(MenuBuilder.helpMenuID, of: menu)?.items.map(\.title) == ["Help Index"])
        #expect(MenuBuilder.submenu(MenuBuilder.windowMenuID, of: menu)?.items.first?.title == "Minimize")
        #expect(MenuBuilder.submenu(MenuBuilder.servicesMenuID, of: menu) != nil)
        // `Sort ▸ …` titles share a submenu.
        let sort = menu.items[4].submenu?.items.first { $0.title == "Sort" }?.submenu
        #expect(sort?.items.map(\.title) == ["With Parameter", "Second"])
        #expect(sort?.items.first.flatMap(MenuBuilder.command(of:)) == "cm_TestParameter")
    }

    /// Without editing commands of the plugins the Edit menu still has the text fields' actions.
    @Test
    internal func aMenuBarWithoutEditingCommandsStillEdits() {
        let kernel = Kernel(productName: "Bare", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.commands.register(Command("cm_One", "One", [.cmd("z")])) {
            // Nothing to do: the command only has to take ⌘Z.
        }
        kernel.menus.add(["cm_One"], to: .filesOpen)
        let menu = MenuBuilder.mainMenu(appName: "Bare", kernel: kernel)
        #expect(menu.items.map(\.title) == ["Bare", "Files", "Edit", "Window"])
        let edit = menu.items[2].submenu?.items ?? []
        #expect(
            edit.map { $0.isSeparatorItem ? "-" : $0.title } == [
                "Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All"
            ]
        )
        // A key that belongs to a command is not taken a second time.
        #expect(edit[0].keyEquivalent.isEmpty && edit[1].keyEquivalent == "z" && edit[4].keyEquivalent == "c")
        // No configuration command, no Settings entry.
        #expect(menu.items[0].submenu?.items.contains { $0.title == "Settings…" } == false)
    }

    /// The last sections of a menu too long for the screen move into a submenu; one without sections stays.
    @Test
    internal func aMenuTooLongForTheScreenFoldsItsLastSections() {
        let commands = CommandRegistry()
        var ids: [CommandID?] = []
        for section in 0..<5 {
            if section > 0 {
                ids.append(nil)
            }
            for entry in 0..<4 {
                let id = CommandID(rawValue: "c\(section)\(entry)")
                commands.register(Command(id, "Entry \(section).\(entry)")) {
                    // Nothing to do: the entry only has to be there.
                }
                ids.append(id)
            }
        }
        let menu = MenuBuilder.menu("Long", ids, commands: commands, keys: nil)
        #expect(menu.items.count == 24)
        MenuBuilder.foldOverflow(of: menu, limit: 30)
        #expect(menu.items.count == 24)
        MenuBuilder.foldOverflow(of: menu, limit: 12)
        // Two sections and their separator stay, the rest is one step away.
        #expect(menu.items.count == 11 && menu.items.last?.title == "More" && menu.items[9].isSeparatorItem)
        let more = menu.items.last?.submenu?.items ?? []
        #expect(more.count == 14 && more.first?.title == "Entry 2.0" && more.last?.title == "Entry 4.3")
        // A menu without sections cannot be folded sensibly.
        let entries: [CommandID] = ids.compactMap(\.self)
        let flat = MenuBuilder.menu("Flat", entries, commands: commands, keys: nil)
        MenuBuilder.foldOverflow(of: flat, limit: 12)
        #expect(flat.items.count == 20)
    }

    /// A menu item takes its title from the command and its key from the bindings.
    @Test
    internal func menuItemsTakeCaptionFromTheCommandAndKeyFromTheBindings() throws {
        let keys = KeyBindings()
        let commands = CommandRegistry(keyBindings: keys)
        commands.register(Command("cm_Copy", "Copy…", [Shortcut(.returnKey), .f(5), .cmd("k")])) {
            // Nothing to do: the entry only has to be there.
        }
        commands.register(Command("cm_Paste", "Paste", [.cmd("v")]).editing(.paste)) {
            // Nothing to do: the entry only has to be there.
        }
        let copy = try #require(commands["cm_Copy"])
        let item = MenuBuilder.item(copy, keys: keys)
        #expect(item.title == "Copy…")
        let keyF5 = try #require(UnicodeScalar(UInt32(NSF5FunctionKey)))
        #expect(item.keyEquivalent == String(keyF5) && item.keyEquivalentModifierMask.isEmpty)
        #expect(MenuBuilder.command(of: item) == "cm_Copy")
        let paste = MenuBuilder.item(try #require(commands["cm_Paste"]), keys: keys)
        #expect(paste.action == #selector(NSText.paste(_:)) && paste.keyEquivalentModifierMask == .command)
        // A context menu shows no keys; a rebound command shows its new key.
        #expect(MenuBuilder.item(copy, keys: nil).keyEquivalent.isEmpty)
        keys.apply(overrides: ["cm_Copy": ["f9"]])
        let keyF9 = try #require(UnicodeScalar(UInt32(NSF9FunctionKey)))
        #expect(MenuBuilder.item(copy, keys: keys).keyEquivalent == String(keyF9))
    }

    /// Names nobody registered and the separators they would leave twice are left out.
    @Test
    internal func menusSkipUnregisteredNamesAndDoubleSeparators() {
        let commands = CommandRegistry()
        commands.register(Command("a", "A")) {
            // Nothing to do: the entry only has to be there.
        }
        commands.register(Command("b", "B")) {
            // Nothing to do: the entry only has to be there.
        }
        let menu = MenuBuilder.menu("Test", [nil, "a", nil, "missing", nil, "b", nil], commands: commands, keys: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["A", "-", "B"])
    }
}
