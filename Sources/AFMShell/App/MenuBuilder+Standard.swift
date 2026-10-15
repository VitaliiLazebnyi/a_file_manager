import AFMContracts
import AFMKernel
import AppKit

/// The menus and entries every Mac program has, around the plugins' menus.
extension MenuBuilder {
    /// A standard editing action the shell adds where no plugin brought it.
    private struct StandardAction {
        /// The caption of its entry.
        let title: String
        /// What the entry sends along the responder chain.
        let action: Selector
        /// Its key, with Cmd.
        let key: String
    }

    /// The editing actions every text field takes from the menu bar, after Undo and Redo.
    private static let standardEditing = [
        StandardAction(title: "Cut", action: #selector(NSText.cut(_:)), key: "x"),
        StandardAction(title: "Copy", action: #selector(NSText.copy(_:)), key: "c"),
        StandardAction(title: "Paste", action: #selector(NSText.paste(_:)), key: "v"),
        StandardAction(title: "Select All", action: #selector(NSResponder.selectAll(_:)), key: "a")
    ]
    /// Adds Undo, Redo and the standard editing actions to the Edit menu.
    ///
    /// Text fields in the main window, in plugin windows and in dialogs take Undo, Cut, Copy,
    /// Paste and Select All from the menu bar, like everywhere on the Mac. Plugins contribute
    /// some of these through commands with an `EditingRole` (they then act on files in a panel
    /// and on text in a text field); whatever no plugin brought is added here as the plain
    /// editing action.
    internal static func addStandardEditing(to edit: NSMenu, in main: NSMenu, keys: KeyBindings) {
        var lead: [NSMenuItem] = [
            standardItem("Undo", Selector(("undo:")), "z", .command, keys: keys),
            standardItem("Redo", Selector(("redo:")), "z", [.command, .shift], keys: keys)
        ]
        let missing = standardEditing.filter { entry in
            !main.items.contains { $0.submenu.map { contains(entry.action, in: $0) } ?? false }
        }
        if !missing.isEmpty {
            lead.append(.separator())
            lead += missing.map { standardItem($0.title, $0.action, $0.key, .command, keys: keys) }
        }
        if !edit.items.isEmpty {
            lead.append(.separator())
        }
        for (index, item) in lead.enumerated() {
            edit.insertItem(item, at: index)
        }
    }

    /// The application menu: About, Settings when a plugin offers them, Services, Hide and Quit.
    internal static func appMenu(appName: String, hasSettings: Bool, keys: KeyBindings) -> NSMenu {
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(
            standardItem("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keys: keys)
        )
        if hasSettings {
            appMenu.addItem(.separator())
            appMenu.addItem(
                standardItem("Settings…", #selector(ShellApplication.showSettings(_:)), ",", .command, keys: keys)
            )
        }
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        services.submenu?.identifier = servicesMenuID
        appMenu.items += [
            .separator(), services, .separator(),
            standardItem("Hide \(appName)", #selector(NSApplication.hide(_:)), "h", .command, keys: keys),
            standardItem(
                "Hide Others",
                #selector(NSApplication.hideOtherApplications(_:)),
                "h",
                [.command, .option],
                keys: keys
            ),
            standardItem("Show All", #selector(NSApplication.unhideAllApplications(_:)), keys: keys),
            .separator(),
            standardItem("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q", .command, keys: keys)
        ]
        return appMenu
    }

    /// The plugins' Edit menu, or one made for the editing actions after the Files menu.
    internal static func editMenu(in main: NSMenu) -> NSMenu {
        if let edit = main.items.first(where: { $0.title == MenuID.edit.title })?.submenu {
            return edit
        }
        let edit = NSMenu(title: MenuID.edit.title)
        let holder = NSMenuItem(title: edit.title, action: nil, keyEquivalent: "")
        holder.submenu = edit
        let afterFiles = main.items.firstIndex { $0.title == MenuID.files.title }.map { $0 + 1 } ?? 1
        main.insertItem(holder, at: afterFiles)
        return edit
    }

    /// The Window menu, with an entry that brings the main window back.
    internal static func windowMenu(appName: String, keys: KeyBindings) -> NSMenu {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.identifier = windowMenuID
        windowMenu.items = [
            standardItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", .command, keys: keys),
            standardItem("Zoom", #selector(NSWindow.performZoom(_:)), keys: keys),
            standardItem(
                "Enter Full Screen",
                #selector(NSWindow.toggleFullScreen(_:)),
                "f",
                [.command, .control],
                keys: keys
            ),
            .separator(),
            standardItem(appName, #selector(ShellApplication.showMainWindow(_:)), "0", .command, keys: keys),
            .separator(),
            standardItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), keys: keys)
        ]
        return windowMenu
    }

    /// An entry of the shell's own menus.
    ///
    /// Its key, `key` with `modifiers`, is left out when the user or a plugin gave that key to
    /// a command: every key is bound in one place. An empty `key` is no key.
    private static func standardItem(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: KeyModifiers,
        keys: KeyBindings
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if !key.isEmpty, keys.command(for: Shortcut(.character(key), modifiers)) == nil {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers.eventFlags
        }
        return item
    }

    /// An entry of the shell's own menus without a key.
    private static func standardItem(_ title: String, _ action: Selector, keys: KeyBindings) -> NSMenuItem {
        standardItem(title, action, "", .command, keys: keys)
    }

    /// Whether `menu` or a menu inside it has an entry that sends `action`.
    private static func contains(_ action: Selector, in menu: NSMenu) -> Bool {
        menu.items.contains { $0.action == action || ($0.submenu.map { contains(action, in: $0) } ?? false) }
    }
}
