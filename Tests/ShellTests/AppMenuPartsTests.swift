import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The parts of the menu bar the shell adds itself: the Edit menu, and the menus the
/// application object is told of.
@MainActor
@Suite(.serialized)
internal struct AppMenuPartsTests {
    /// Makes sure AppKit is there for the menus.
    internal init() {
        _ = NSApplication.shared
    }

    /// Without a Files menu the Edit menu comes right after the program's menu.
    @Test
    internal func anEditMenuWithoutAFilesMenuComesSecond() {
        let main = NSMenu(title: "Main")
        for title in ["Program", "Window"] {
            main.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        let edit = MenuBuilder.editMenu(in: main)
        #expect(main.items.map(\.title) == ["Program", "Edit", "Window"] && main.items[1].submenu === edit)
        #expect(MenuBuilder.editMenu(in: main) === edit)
        // Entries without a menu of their own hold no editing action.
        MenuBuilder.addStandardEditing(to: edit, in: main, keys: KeyBindings())
        #expect(
            edit.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
                "Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All"
            ]
        )
    }

    /// The application object is told which menus are the Services, Window and Help menus.
    @Test
    internal func installingTellsTheApplicationOfTheSpecialMenus() {
        let kernel = Kernel(productName: "Bare", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.commands.register(Command("cm_Help", "Help Index")) {
            // Nothing to do: the entry only has to be there.
        }
        kernel.menus.add(["cm_Help"], to: .helpTopics)
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let main = MenuBuilder.mainMenu(appName: "Bare", kernel: kernel)
        MenuBuilder.install(main)
        #expect(NSApp.mainMenu === main)
        #expect(NSApp.servicesMenu === MenuBuilder.submenu(MenuBuilder.servicesMenuID, of: main))
        #expect(NSApp.windowsMenu === MenuBuilder.submenu(MenuBuilder.windowMenuID, of: main))
        #expect(NSApp.helpMenu === MenuBuilder.submenu(MenuBuilder.helpMenuID, of: main))
        // A bar without a Help menu leaves the one the application had.
        let bare = MenuBuilder.mainMenu(
            appName: "Bare",
            kernel: Kernel(productName: "Bare", settings: MemorySettings(), interaction: ScriptedInteraction())
        )
        let help = NSApp.helpMenu
        MenuBuilder.install(bare)
        #expect(NSApp.mainMenu === bare && NSApp.helpMenu === help)
    }
}
