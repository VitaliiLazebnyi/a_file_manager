import AFMContracts
import AFMKernel
import AppKit

/// Changes to the menu bar while the program runs.
///
/// The shell builds its menus once, from the registries; its items carry the name of their command,
/// which is all that is relied on here.
@MainActor
internal enum LiveMenus {
    private static let slotPrefix = "cm_UserMenu"

    /// The menu keys of the named keys a menu can show, other than the function keys; the keys
    /// of the numeric keypad have none.
    private static let menuKeys: [Key: String] = [
        .returnKey: "\r", .tab: "\t", .backspace: "\u{8}", .forwardDelete: special(NSDeleteFunctionKey),
        .home: special(NSHomeFunctionKey), .end: special(NSEndFunctionKey),
        .pageUp: special(NSPageUpFunctionKey), .pageDown: special(NSPageDownFunctionKey),
        .leftArrow: special(NSLeftArrowFunctionKey), .rightArrow: special(NSRightArrowFunctionKey),
        .upArrow: special(NSUpArrowFunctionKey), .downArrow: special(NSDownArrowFunctionKey)
    ]

    /// The character AppKit uses for one of its special keys: they lie in one block of 16-bit code units.
    nonisolated private static func special(_ value: Int) -> String {
        String(utf16CodeUnits: [UInt16(truncatingIfNeeded: value)], count: 1)
    }

    /// The key as a menu shows it; nil for keys a menu cannot show.
    ///
    /// The same rule as the shell's.
    private static func menuEquivalent(_ key: Key) -> String? {
        switch key {
        case .character(let character):
            return character

        case .function(let number):
            return special(NSF1FunctionKey + number - 1)

        default:
            return menuKeys[key]
        }
    }

    /// Plain typing keys stay with text fields, so a menu owns only function keys and keys
    /// with Cmd, Ctrl or Option.
    private static func menuKey(_ shortcut: Shortcut) -> String? {
        guard let key = menuEquivalent(shortcut.key) else {
            return nil
        }
        if case .function = shortcut.key {
            return key
        }
        return shortcut.modifiers.isDisjoint(with: [.command, .control, .option]) ? nil : key
    }

    private static func flags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Shows the keys in force next to every menu item that stands for a command.
    internal static func refreshKeys(in menu: NSMenu, kernel: Kernel) {
        for item in menu.items {
            if let submenu = item.submenu { refreshKeys(in: submenu, kernel: kernel) }
            guard let name = item.representedObject as? String, kernel.commands[CommandID(rawValue: name)] != nil else {
                continue
            }
            let shortcut = kernel.keyBindings.shortcuts(for: CommandID(rawValue: name)).first { menuKey($0) != nil }
            item.keyEquivalent = shortcut.flatMap(menuKey) ?? ""
            item.keyEquivalentModifierMask = shortcut.map { flags($0.modifiers) } ?? []
        }
    }

    /// Replaces the user's entries of the Start menu by the current ones; the menu's fixed
    /// entries stay below them.
    ///
    /// Does nothing when the menu bar has no Start menu.
    internal static func rebuildStartMenu(in mainMenu: NSMenu, entries: [StartMenuEntry], target: StartMenuTarget) {
        guard let menu = mainMenu.items.first(where: { $0.submenu?.title == MenuID.start.title })?.submenu else {
            return
        }
        let fixed = menu.items.filter { item in
            guard let name = item.representedObject as? String else {
                return false
            }
            return !name.hasPrefix(slotPrefix)
        }
        menu.removeAllItems()
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            let item = NSMenuItem(
                title: DisplayText.oneLine(entry.title.replacingOccurrences(of: "&", with: ""), limit: 120),
                action: #selector(StartMenuTarget.runEntry(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = StartMenuEntry.commandID(at: index).rawValue
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == false, !fixed.isEmpty { menu.addItem(.separator()) }
        fixed.forEach(menu.addItem)
    }
}
