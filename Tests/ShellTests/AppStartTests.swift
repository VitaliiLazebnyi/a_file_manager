import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The whole program as it starts: the panels of the last session, and the menus, keys and
/// function-key bar the plugins bring.
@MainActor
@Suite(.serialized)
internal struct AppStartTests {
    /// The program's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// Each panel shows the folder it showed when the program was left, the left one as the source.
    @Test
    internal func startsWithThePanelsOfTheLastSession() async {
        let app = await fixture.startProgram()
        defer { app.stop() }
        #expect(app.names(app.left) == ["docs", "one.txt", "two.txt"] && app.names(app.right) == ["one.txt"])
        #expect(app.kernel.panels.source === app.left && app.left.isActive && !app.right.isActive)
        #expect(app.left.tableView.numberOfRows == 4)
        #expect(
            app.kernel.plugins.count >= 21
                && Array(app.kernel.fileSystems.all.map(\.scheme).prefix(2)) == ["mem", "file"]
        )
    }

    /// A folder of the last session that is gone is replaced by the home folder, without a word.
    @Test
    internal func aFolderThatIsGoneIsReplacedAtStartUp() async {
        fixture.settings.set(
            PanelTabs.State(tabs: [.init(location: fixture.box.url("vanished"))], active: 0),
            forKey: "left.tabs"
        )
        let app = await fixture.startProgram()
        defer { app.stop() }
        #expect(app.left.model.directory.lastPathComponent == "home" && app.names(app.left) == ["welcome.txt"])
        #expect(fixture.user.log.isEmpty)
    }

    /// The menus, the keys, the function-key bar and the context menus are what the plugins registered.
    @Test
    internal func menusKeysAndFunctionBarComeFromThePlugins() async throws {
        let app = await fixture.startProgram()
        defer { app.stop() }
        let menu = app.shell.makeMainMenu()
        let titles = menu.items.map(\.title)
        #expect(titles.first == "A File Manager" && titles.contains("Window"))
        #expect(
            titles.filter(["Files", "Edit", "Mark", "Commands", "Show"].contains) == [
                "Files", "Edit", "Mark", "Commands", "Show"
            ]
        )
        let menuCommands = menu.items.flatMap { $0.submenu?.items ?? [] }.compactMap(MenuBuilder.command(of:))
        #expect(Set(menuCommands).count == menuCommands.count)
        let contributed =
            app.kernel.menus.menus.flatMap(\.items).compactMap(\.self)
            + app.kernel.menus.contextMenu(onItem: true).compactMap(\.self)
        #expect(contributed.allSatisfy { app.commands[$0] != nil })
        #expect(app.kernel.keyClashes.isEmpty)
        #expect(
            app.window.functionKeyBar.entries.map(\.title) == [
                "F3 View", "F4 Edit", "F5 Copy", "F6 Move", "F7 NewFolder", "F8 Delete", "⌘Q Exit"
            ]
        )
        let copyItem = MenuBuilder.item(try #require(app.commands[.copy]), keys: app.kernel.keyBindings)
        #expect(!app.window.validateMenuItem(copyItem))
        app.cursor(app.left, on: "one.txt")
        #expect(app.window.validateMenuItem(copyItem))
        // The context menu on an item and on empty space.
        let onItem = app.left.contextMenu(forRow: 2)?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        #expect(
            onItem.starts(with: ["Open", "View", "Edit", "Open Folder in New Tab", "Copy…"]) && onItem.contains("Paste")
        )
        let onSpace = app.left.contextMenu(forRow: -1)?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        #expect(onSpace.first == "Paste" && !onSpace.contains("Open"))
    }

    /// Keys the user bound otherwise move in the menus and on the function-key bar, and work.
    @Test
    internal func theUsersKeyBindingsChangeMenuAndFunctionBar() async throws {
        fixture.settings.set(["cm_Copy": ["f9"], "cm_List": ["f5"]], forKey: KeyBindings.settingsKey)
        let app = await fixture.startProgram()
        defer { app.stop() }
        #expect(
            app.window.functionKeyBar.entries.map(\.title) == [
                "F4 Edit", "F5 View", "F6 Move", "F7 NewFolder", "F8 Delete", "F9 Copy", "⌘Q Exit"
            ]
        )
        let copyItem = MenuBuilder.item(try #require(app.commands[.copy]), keys: app.kernel.keyBindings)
        let keyF9 = try #require(UnicodeScalar(UInt32(NSF9FunctionKey)))
        #expect(copyItem.keyEquivalent == String(keyF9))
        // F9 (key code 101) now copies: with the cursor on a file the prompt appears.
        app.cursor(app.left, on: "two.txt")
        fixture.user.promptAnswers = [.cancel]
        #expect(try app.press(101, []))
        #expect(fixture.user.log == ["prompt: Copy \"two.txt\" to [\(fixture.box.url("B").path)/two.txt]"])
    }
}
