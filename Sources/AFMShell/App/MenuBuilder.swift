import AFMContracts
import AFMKernel
import AppKit

/// Builds menus from what the plugins registered.
///
/// Captions come from the command registry, keys from the key bindings, the layout from the
/// menu registry. The shell adds what every Mac program has: the application menu, the
/// standard editing actions and the Window menu. Main thread only.
@MainActor
internal enum MenuBuilder {
    /// Menu items send this action along the responder chain; the main window answers it.
    internal static let action = #selector((any CommandResponder).performCommand(_:))
    /// The mark that puts a command into a submenu.
    ///
    /// A command whose title is written `Sort ▸ By Name` appears as *By Name* in a submenu
    /// *Sort* of its menu. The submenu stands where its first command would have stood.
    internal static let submenuMark = " ▸ "
    /// The title of the submenu that takes the sections a long menu has no room for.
    internal static let overflowTitle = "More"
    /// Identifies the Window menu, which the application object wants to know (`NSApp.windowsMenu`).
    internal static let windowMenuID = NSUserInterfaceItemIdentifier("afm.menu.window")
    /// Identifies the Help menu, which the application object wants to know (`NSApp.helpMenu`).
    internal static let helpMenuID = NSUserInterfaceItemIdentifier("afm.menu.help")
    /// Identifies the Services menu, which the application object fills (`NSApp.servicesMenu`).
    internal static let servicesMenuID = NSUserInterfaceItemIdentifier("afm.menu.services")
    /// The key of the object that answers for the keys of a menu bar, kept with the bar.
    private static var keyAnswersKey = 0

    /// The number of entries a menu can show without scrolling on the main screen.
    internal static var screenLimit: Int {
        limit(forScreenHeight: NSScreen.main?.visibleFrame.height)
    }

    /// The number of entries a menu can show without scrolling on a screen `height` points
    /// high; 36 when there is no screen to ask.
    internal static func limit(forScreenHeight height: CGFloat?) -> Int {
        guard let height else {
            return 36
        }
        return max(20, Int(height / 22) - 2)
    }

    /// The entry of a command, with its title and the key the bindings give it.
    ///
    /// Without `keys` the entry shows no key (context menus). A command with an editing role
    /// sends the standard editing action, so that a text field gets it while it is typed in.
    internal static func item(_ command: Command, keys: KeyBindings?) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: command.editingRole.map(selector(for:)) ?? action,
            keyEquivalent: ""
        )
        item.representedObject = command.id.rawValue
        if let shortcut = keys?.menuShortcut(for: command.id), let key = shortcut.key.menuEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = shortcut.modifiers.eventFlags
        }
        return item
    }

    /// A menu of commands.
    ///
    /// `nil` entries become separators. Names no plugin registered are left out. Without `keys`
    /// the items show no shortcuts (context menus).
    internal static func menu(
        _ title: String,
        _ ids: [CommandID?],
        commands: CommandRegistry,
        keys: KeyBindings?
    ) -> NSMenu {
        let menu = NSMenu(title: title)
        var submenus: [String: NSMenu] = [:]
        for id in ids {
            guard let id else {
                if menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                continue
            }
            guard let command = commands[id] else {
                continue
            }
            let item = item(command, keys: keys)
            guard let mark = command.title.range(of: submenuMark), mark.lowerBound > command.title.startIndex else {
                menu.addItem(item)
                continue
            }
            let parent = String(command.title[..<mark.lowerBound])
            item.title = String(command.title[mark.upperBound...])
            if submenus[parent] == nil {
                let holder = NSMenuItem(title: parent, action: nil, keyEquivalent: "")
                holder.submenu = NSMenu(title: parent)
                submenus[parent] = holder.submenu
                menu.addItem(holder)
            }
            submenus[parent]?.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        return menu
    }

    /// The command of an entry built by `item`; nil for any other entry.
    internal static func command(of item: NSMenuItem) -> CommandID? {
        (item.representedObject as? String).map(CommandID.init(rawValue:))
    }

    /// Folds the last sections of a menu that is too long into a submenu.
    ///
    /// A menu with more entries than fit on the screen would have to be scrolled. Its last
    /// sections move into a submenu instead, so that at most `limit` entries remain; their keys
    /// work as before. A menu without sections is left as it is.
    internal static func foldOverflow(of menu: NSMenu, limit: Int) {
        guard menu.items.count > limit else {
            return
        }
        // The last separator that leaves room for the submenu's own entry.
        let cut = menu.items.indices.last { menu.items[$0].isSeparatorItem && $0 < limit - 1 }
        guard let cut, cut > 0 else {
            return
        }
        let more = NSMenu(title: overflowTitle)
        let moved = Array(menu.items[(cut + 1)...])
        moved.forEach(menu.removeItem)
        moved.forEach(more.addItem)
        let holder = NSMenuItem(title: overflowTitle, action: nil, keyEquivalent: "")
        holder.submenu = more
        menu.addItem(holder)
    }

    /// The menu with `identifier` in `main` or in one of its menus; nil when there is none.
    internal static func submenu(_ identifier: NSUserInterfaceItemIdentifier, of main: NSMenu) -> NSMenu? {
        if let found = main.items.first(where: { $0.submenu?.identifier == identifier })?.submenu {
            return found
        }
        return main.items.lazy.compactMap { $0.submenu.flatMap { submenu(identifier, of: $0) } }.first
    }

    /// The menu bar for the main screen.
    internal static func mainMenu(appName: String, kernel: Kernel) -> NSMenu {
        mainMenu(appName: appName, kernel: kernel, limit: screenLimit)
    }

    /// The menu bar, with menus of at most `limit` entries.
    ///
    /// The application menu, the plugins' menus in their order, the Window menu, and the
    /// plugins' Help menu last, where the Mac has it. The plugins' menus answer for their keys
    /// themselves (`MenuKeys`); the menus around them, a handful of standard entries, are left
    /// to the system.
    internal static func mainMenu(appName: String, kernel: Kernel, limit: Int) -> NSMenu {
        let main = NSMenu()
        let keys = kernel.keyBindings
        add(appMenu(appName: appName, hasSettings: kernel.commands[.configuration] != nil, keys: keys), to: main)
        var help: NSMenu?
        for contributed in kernel.menus.menus {
            let menu = menu(contributed.title, contributed.items, commands: kernel.commands, keys: keys)
            if contributed.title == MenuID.help.title {
                menu.identifier = helpMenuID
                help = menu
            } else {
                add(menu, to: main)
            }
        }
        addStandardEditing(to: editMenu(in: main), in: main, keys: keys)
        let keyAnswers = MenuKeys(kernel: kernel)
        for holder in main.items.dropFirst() {
            holder.submenu.map { foldOverflow(of: $0, limit: limit) }
            holder.submenu.map(keyAnswers.answer(for:))
        }
        add(windowMenu(appName: appName, keys: keys), to: main)
        if let help {
            add(help, to: main)
            keyAnswers.answer(for: help)
        }
        // A menu holds its delegate weakly; this one lives as long as the menu bar.
        objc_setAssociatedObject(main, &keyAnswersKey, keyAnswers, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return main
    }

    /// Makes a menu bar built by `mainMenu` the program's.
    ///
    /// The application object is told which of its menus are the Services, Window and Help
    /// menus: the system fills the first two and puts its search field into the third.
    internal static func install(_ main: NSMenu) {
        NSApp.mainMenu = main
        NSApp.servicesMenu = submenu(servicesMenuID, of: main)
        NSApp.windowsMenu = submenu(windowMenuID, of: main)
        if let help = submenu(helpMenuID, of: main) {
            NSApp.helpMenu = help
        }
    }

    /// The standard action of an editing role, sent along the responder chain.
    private static func selector(for role: EditingRole) -> Selector {
        switch role {
        case .cut:
            return #selector(NSText.cut(_:))

        case .copy:
            return #selector(NSText.copy(_:))

        case .paste:
            return #selector(NSText.paste(_:))

        case .selectAll:
            return #selector(NSResponder.selectAll(_:))
        }
    }

    /// Adds `menu` to the menu bar `main`, under its title.
    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }
}
