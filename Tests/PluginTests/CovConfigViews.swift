import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The views the configuration windows are made of, and the changes to the menu bar.
@MainActor
@Suite
internal struct CovConfigViews {
    /// The character AppKit uses for a special key.
    private static func special(_ value: Int) -> String {
        String(utf16CodeUnits: [UInt16(value)], count: 1)
    }

    /// The modifier keys of a menu item for those of a shortcut.
    private static func flags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        let pairs: [(KeyModifiers, NSEvent.ModifierFlags)] = [
            (.shift, .shift), (.control, .control), (.option, .option), (.command, .command)
        ]
        return pairs.reduce(into: []) { flags, pair in
            if modifiers.contains(pair.0) { flags.insert(pair.1) }
        }
    }

    /// A list with two columns.
    private func table() -> RowsTable {
        RowsTable(columns: [("One", 100), ("Two", 100)])
    }

    private func text(_ table: RowsTable, column: NSTableColumn?, row: Int) -> String? {
        (table.tableView(table.tableView, viewFor: column, row: row) as? NSTableCellView)?.textField?.stringValue
    }

    private func key(_ code: UInt16, _ characters: String) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )
    }

    /// A row with fewer texts than columns leaves the rest empty; a full-width row shows the first;
    /// a symbol that does not exist shows an empty picture.
    @Test
    internal func cellsOfShortRowsAndUnknownSymbols() {
        let list = table()
        list.show([["only"]], symbols: ["no.such.symbol.here"])
        let columns = list.tableView.tableColumns
        #expect(
            text(list, column: columns[0], row: 0) == "only" && text(list, column: columns[1], row: 0)?.isEmpty == true
        )
        #expect(text(list, column: nil, row: 0) == "only")
        let cell = list.tableView(list.tableView, viewFor: columns[0], row: 0)
        #expect(cell?.subviews.contains { $0 is NSImageView } == true)
    }

    /// Return and Enter activate the row; other keys go to the list; a double click outside the rows does nothing.
    @Test
    internal func returnAndEnterActivateTheRow() throws {
        let list = table()
        list.show([["a"], ["b"]])
        var activated = 0
        list.onActivate = { activated += 1 }
        list.tableView.keyDown(with: try #require(key(36, "\r")))
        list.tableView.keyDown(with: try #require(key(76, "\u{3}")))
        list.tableView.keyDown(with: try #require(key(125, "\u{F701}")))
        let view = list.tableView
        view.sendAction(view.doubleAction, to: view.target)
        #expect(activated == 2)
    }

    /// An entry of the rebuilt Start menu runs its command when that is enabled, and is offered only then.
    @Test
    internal func startMenuEntriesRunTheirCommands() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        var runs = 0
        stage.commands.register(Command("cov_entry", "Entry")) { runs += 1 }
        let target = StartMenuTarget(kernel: stage.bench.kernel)
        let item = NSMenuItem(title: "Entry", action: #selector(StartMenuTarget.runEntry(_:)), keyEquivalent: "")
        item.representedObject = "cov_entry"
        #expect(target.validateMenuItem(item))
        target.runEntry(item)
        let plain = NSMenuItem(title: "Plain", action: nil, keyEquivalent: "")
        #expect(!target.validateMenuItem(plain))
        target.runEntry(plain)
        #expect(runs == 1)
    }

    /// The menu items of commands show the keys a menu can show: function keys alone, other keys
    /// only with Cmd, Ctrl or Option.
    @Test
    internal func menuItemsShowTheKeysAMenuCanShow() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let cases: [(Shortcut, String)] = [
            (.f(5), Self.special(NSF5FunctionKey)),
            (Shortcut(.returnKey, .command), "\r"),
            (Shortcut(.tab, .option), "\t"),
            (Shortcut(.backspace, [.command, .shift]), "\u{8}"),
            (Shortcut(.forwardDelete, .command), Self.special(NSDeleteFunctionKey)),
            (Shortcut(.home, .command), Self.special(NSHomeFunctionKey)),
            (Shortcut(.end, .command), Self.special(NSEndFunctionKey)),
            (Shortcut(.pageUp, .command), Self.special(NSPageUpFunctionKey)),
            (Shortcut(.pageDown, .command), Self.special(NSPageDownFunctionKey)),
            (Shortcut(.leftArrow, [.control, .option]), Self.special(NSLeftArrowFunctionKey)),
            (Shortcut(.rightArrow, [.control, .option]), Self.special(NSRightArrowFunctionKey)),
            (Shortcut(.upArrow, .control), Self.special(NSUpArrowFunctionKey)),
            (Shortcut(.downArrow, .control), Self.special(NSDownArrowFunctionKey)),
            (Shortcut(.space, .command), ""),
            (Shortcut(.character("q"), .shift), "")
        ]
        let menu = NSMenu()
        let submenu = NSMenu()
        for (index, entry) in cases.enumerated() {
            let id = CommandID(rawValue: "cov_key\(index)")
            stage.commands.register(Command(id, "Key \(index)", [entry.0])) {
                // A command with a key, nothing else.
            }
            let item = NSMenuItem(title: "Key \(index)", action: nil, keyEquivalent: "")
            item.representedObject = id.rawValue
            submenu.addItem(item)
        }
        let unknown = NSMenuItem(title: "Gone", action: nil, keyEquivalent: "g")
        unknown.representedObject = "cov_gone"
        submenu.addItem(unknown)
        let holder = NSMenuItem(title: "Keys", action: nil, keyEquivalent: "")
        holder.submenu = submenu
        menu.addItem(holder)
        LiveMenus.refreshKeys(in: menu, kernel: stage.bench.kernel)
        for (index, entry) in cases.enumerated() {
            let item = submenu.items[index]
            let mask = entry.1.isEmpty ? [] : Self.flags(entry.0.modifiers)
            #expect(item.keyEquivalent == entry.1 && item.keyEquivalentModifierMask == mask, "\(entry.0)")
        }
        #expect(unknown.keyEquivalent == "g")
    }

    /// The Start menu is rebuilt without separators at its start or two in a row; a menu bar
    /// without a Start menu is left alone, and so are its items without a command.
    @Test
    internal func theStartMenuIsRebuiltWithTidySeparators() throws {
        let stage = try CovConfigStage()
        defer { stage.close() }
        let target = StartMenuTarget(kernel: stage.bench.kernel)
        let entry = StartMenuEntry(title: "Build", action: CommandAction(command: "make"))
        let lonely = NSMenu()
        LiveMenus.rebuildStartMenu(in: lonely, entries: [entry], target: target)
        #expect(lonely.items.isEmpty)
        let bar = NSMenu()
        let start = NSMenu(title: MenuID.start.title)
        start.addItem(NSMenuItem(title: "Loose", action: nil, keyEquivalent: ""))
        let holder = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        holder.submenu = start
        bar.addItem(holder)
        LiveMenus.rebuildStartMenu(in: bar, entries: [.separator, entry, .separator, .separator, entry], target: target)
        #expect(start.items.map(\.title) == ["Build", "", "Build"])
    }
}
