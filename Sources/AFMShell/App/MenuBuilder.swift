import AFMContracts
import AFMKernel
import AppKit

/// Builds menus from what the plugins registered: captions from the command registry, keys
/// from the key bindings, layout from the menu registry. The shell adds what every Mac program
/// has: the application menu, the standard editing actions and the Window menu.
enum MenuBuilder {
    /// Menu items send this action along the responder chain; the main window answers it.
    static let action = #selector(CommandResponder.performCommand(_:))

    /// A command whose title is written `Sort ▸ By Name` appears as *By Name* in a submenu
    /// *Sort* of its menu. The submenu stands where its first command would have stood.
    static let submenuMark = " ▸ "

    /// The title of the submenu that takes the sections a long menu has no room for.
    static let overflowTitle = "More"

    private static func selector(for role: EditingRole) -> Selector {
        switch role {
        case .cut: return #selector(NSText.cut(_:))
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSResponder.selectAll(_:))
        }
    }

    static func item(_ command: Command, keys: KeyBindings?) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title, action: command.editingRole.map(selector(for:)) ?? action, keyEquivalent: "")
        item.representedObject = command.id.rawValue
        if let shortcut = keys?.menuShortcut(for: command.id), let key = shortcut.key.menuEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = shortcut.modifiers.eventFlags
        }
        return item
    }

    /// `nil` entries become separators. Names no plugin registered are left out. Without
    /// `keys` the items show no shortcuts (context menus).
    static func menu(_ title: String = "", _ ids: [CommandID?], commands: CommandRegistry, keys: KeyBindings?) -> NSMenu
    {
        let menu = NSMenu(title: title)
        var submenus: [String: NSMenu] = [:]
        for id in ids {
            guard let id else {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            guard let command = commands[id] else { continue }
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
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    static func command(of item: NSMenuItem) -> CommandID? {
        (item.representedObject as? String).map(CommandID.init(rawValue:))
    }

    /// A menu with more entries than fit on the screen would have to be scrolled. Its last
    /// sections move into a submenu instead, so that at most `limit` entries remain; their
    /// keys work as before. A menu without sections is left as it is.
    static func foldOverflow(of menu: NSMenu, limit: Int) {
        guard menu.items.count > limit else { return }
        // The last separator that leaves room for the submenu's own entry.
        guard let cut = menu.items.indices.last(where: { menu.items[$0].isSeparatorItem && $0 < limit - 1 }), cut > 0
        else { return }
        let more = NSMenu(title: overflowTitle)
        let moved = Array(menu.items[(cut + 1)...])
        moved.forEach(menu.removeItem)
        moved.forEach(more.addItem)
        let holder = NSMenuItem(title: overflowTitle, action: nil, keyEquivalent: "")
        holder.submenu = more
        menu.addItem(holder)
    }

    /// The number of entries a menu can show without scrolling on the main screen.
    static var screenLimit: Int {
        guard let height = NSScreen.main?.visibleFrame.height else { return 36 }
        return max(20, Int(height / 22) - 2)
    }

    /// An entry of the shell's own menus. Its key is left out when the user or a plugin gave
    /// that key to a command: every key is bound in one place.
    private static func standardItem(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: KeyModifiers = .command,
        keys: KeyBindings
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if !key.isEmpty, keys.command(for: Shortcut(.character(key), modifiers)) == nil {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers.eventFlags
        }
        return item
    }

    private static func contains(_ action: Selector, in menu: NSMenu) -> Bool {
        menu.items.contains { $0.action == action || ($0.submenu.map { contains(action, in: $0) } ?? false) }
    }

    /// Text fields in the main window, in plugin windows and in dialogs take Undo, Cut, Copy,
    /// Paste and Select All from the menu bar, like everywhere on the Mac. Plugins contribute
    /// some of these through commands with an `EditingRole` (they then act on files in a panel
    /// and on text in a text field); whatever no plugin brought is added here as the plain
    /// editing action.
    static func addStandardEditing(to edit: NSMenu, in main: NSMenu, keys: KeyBindings) {
        var lead: [NSMenuItem] = [
            standardItem("Undo", Selector(("undo:")), "z", keys: keys),
            standardItem("Redo", Selector(("redo:")), "z", [.command, .shift], keys: keys)
        ]
        let standard: [(String, Selector, String)] = [
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSResponder.selectAll(_:)), "a")
        ]
        let missing = standard.filter { entry in
            !main.items.contains { $0.submenu.map { contains(entry.1, in: $0) } ?? false }
        }
        if !missing.isEmpty {
            lead.append(.separator())
            lead += missing.map { standardItem($0.0, $0.1, $0.2, keys: keys) }
        }
        if !edit.items.isEmpty { lead.append(.separator()) }
        for (index, item) in lead.enumerated() { edit.insertItem(item, at: index) }
    }

    /// Identifies the menus the application object wants to know (`NSApp.windowsMenu`, `NSApp.helpMenu`).
    static let windowMenuID = NSUserInterfaceItemIdentifier("afm.menu.window")
    static let helpMenuID = NSUserInterfaceItemIdentifier("afm.menu.help")
    static let servicesMenuID = NSUserInterfaceItemIdentifier("afm.menu.services")

    static func submenu(_ identifier: NSUserInterfaceItemIdentifier, of main: NSMenu) -> NSMenu? {
        if let found = main.items.first(where: { $0.submenu?.identifier == identifier })?.submenu { return found }
        return main.items.lazy.compactMap { $0.submenu.flatMap { submenu(identifier, of: $0) } }.first
    }

    /// The menu bar: the application menu, the plugins' menus in their order, the Window menu,
    /// and the plugins' Help menu last, where the Mac has it.
    static func mainMenu(appName: String, kernel: Kernel, limit: Int = Self.screenLimit) -> NSMenu {
        let main = NSMenu()
        let keys = kernel.keyBindings
        func add(_ menu: NSMenu) {
            let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(
            standardItem("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keys: keys))
        if kernel.commands[.configuration] != nil {
            appMenu.addItem(.separator())
            appMenu.addItem(standardItem("Settings…", #selector(ShellApplication.showSettings(_:)), ",", keys: keys))
        }
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        services.submenu?.identifier = servicesMenuID
        appMenu.items += [
            .separator(), services, .separator(),
            standardItem("Hide \(appName)", #selector(NSApplication.hide(_:)), "h", keys: keys),
            standardItem(
                "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], keys: keys
            ),
            standardItem("Show All", #selector(NSApplication.unhideAllApplications(_:)), keys: keys),
            .separator(),
            standardItem("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q", keys: keys)
        ]
        add(appMenu)

        var help: NSMenu?
        for contributed in kernel.menus.menus {
            let menu = menu(contributed.title, contributed.items, commands: kernel.commands, keys: keys)
            if contributed.title == MenuID.help.title {
                menu.identifier = helpMenuID
                help = menu
            } else {
                add(menu)
            }
        }
        // The editing actions live in the plugins' Edit menu, or in one made for them.
        if let edit = main.items.first(where: { $0.title == MenuID.edit.title })?.submenu {
            addStandardEditing(to: edit, in: main, keys: keys)
        } else {
            let edit = NSMenu(title: MenuID.edit.title)
            let holder = NSMenuItem(title: edit.title, action: nil, keyEquivalent: "")
            holder.submenu = edit
            let afterFiles = main.items.firstIndex { $0.title == MenuID.files.title }.map { $0 + 1 } ?? 1
            main.insertItem(holder, at: afterFiles)
            addStandardEditing(to: edit, in: main, keys: keys)
        }
        for holder in main.items.dropFirst() { holder.submenu.map { foldOverflow(of: $0, limit: limit) } }

        let windowMenu = NSMenu(title: "Window")
        windowMenu.identifier = windowMenuID
        windowMenu.items = [
            standardItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", keys: keys),
            standardItem("Zoom", #selector(NSWindow.performZoom(_:)), keys: keys),
            standardItem(
                "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], keys: keys),
            .separator(),
            standardItem(appName, #selector(ShellApplication.showMainWindow(_:)), "0", keys: keys),
            .separator(),
            standardItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), keys: keys)
        ]
        add(windowMenu)
        if let help { add(help) }
        // The plugins' menus answer for their keys themselves (`MenuKeys`); the menus around
        // them, a handful of standard entries, are left to the system.
        let keyAnswers = MenuKeys(kernel: kernel)
        for holder in main.items {
            guard let menu = holder.submenu, menu !== appMenu, menu !== windowMenu else { continue }
            keyAnswers.answer(for: menu)
        }
        // A menu holds its delegate weakly; this one lives as long as the menu bar.
        objc_setAssociatedObject(main, &keyAnswersKey, keyAnswers, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return main
    }

    private static var keyAnswersKey = 0

    /// The object that answers for the keys of a menu bar built by `mainMenu`.
    static func keyAnswers(of main: NSMenu) -> MenuKeys? {
        objc_getAssociatedObject(main, &keyAnswersKey) as? MenuKeys
    }

    /// Makes a menu bar built by `mainMenu` the program's, and tells the application object
    /// which of its menus are the Services, Window and Help menus: the system fills the first
    /// two and puts its search field into the third.
    static func install(_ main: NSMenu) {
        NSApp.mainMenu = main
        NSApp.servicesMenu = submenu(servicesMenuID, of: main)
        NSApp.windowsMenu = submenu(windowMenuID, of: main)
        if let help = submenu(helpMenuID, of: main) { NSApp.helpMenu = help }
    }
}

@objc protocol CommandResponder {
    func performCommand(_ sender: NSMenuItem)
}

/// Keeps the entries of the plugins' menus up to date, and answers the menu bar's question
/// whether a key belongs to one of them.
///
/// Every key that is pressed, letters and arrows included, is first offered to the menu bar.
/// A menu that enables its entries automatically is brought up to date for that, entry by
/// entry, which runs the `enabled` and `checked` functions of all commands, once per key
/// (and a delegate that merely says "not mine" does not stop it). So the menus this object
/// answers for do not enable their entries automatically. Instead:
/// - when such a menu is about to be shown, its entries are brought up to date here
///   (`menuNeedsUpdate`), the same way the menu itself would: by asking whoever would get
///   each entry's action;
/// - for a key, the key is looked up (in the key bindings for commands, by the entry's own
///   key for the few standard editing entries), and if an entry has it, that one entry is
///   checked and named as what is to run. No other entry is looked at.
///
/// Main thread only.
final class MenuKeys: NSObject, NSMenuDelegate {
    private let kernel: Kernel
    /// The entry the last key belonged to, until its action has run.
    private var matched: NSMenuItem?
    /// How often a key was looked up, and how many entries were checked for it; for checks.
    private(set) var lookups = 0
    private(set) var validations = 0

    init(kernel: Kernel) {
        self.kernel = kernel
    }

    /// Makes this object answer for a menu and all menus inside it.
    func answer(for menu: NSMenu) {
        menu.delegate = self
        menu.autoenablesItems = false
        for item in menu.items { item.submenu.map(answer(for:)) }
    }

    /// The menu is about to be shown: its entries follow their commands, as an automatically
    /// enabling menu's would. (Not called for a key: `menuHasKeyEquivalent` answers those.)
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && !item.hasSubmenu {
            let isEnabled = isEnabled(item)
            if item.isEnabled != isEnabled { item.isEnabled = isEnabled }
        }
    }

    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        lookups += 1
        guard event.type == .keyDown, let item = item(in: menu, for: event) else { return false }
        // The entry shows what was found out about it, also to the menu's own search for the
        // key, which follows when this says no.
        let isEnabled = isEnabled(item)
        if item.isEnabled != isEnabled { item.isEnabled = isEnabled }
        guard isEnabled else { return false }
        matched = item
        target.pointee = self
        action.pointee = #selector(performMatched(_:))
        return true
    }

    /// Runs the action of the entry the key belonged to, with the entry as its sender, the way
    /// choosing it from the menu would.
    @objc func performMatched(_: Any?) {
        guard let item = matched else { return }
        matched = nil
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    /// The characters of the keys of an American keyboard, by key code: what a key with Cmd
    /// means while the keyboard writes another script (Cmd+C is Cmd+C on a Russian keyboard too).
    private static let plainKeys: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`"
    ]

    /// The shortcuts a key press can stand for, as the file lists read keys, and for a
    /// keyboard that writes no Latin letters also the key's Latin meaning.
    static func shortcuts(for event: NSEvent) -> [Shortcut] {
        var shortcuts = Shortcut.candidates(for: event)
        if Key(keyCode: event.keyCode) == nil, let typed = event.charactersIgnoringModifiers,
            typed.unicodeScalars.contains(where: { $0.value >= 0x80 }),
            let plain = plainKeys[event.keyCode]
        {
            shortcuts.append(Shortcut(.character(plain), KeyModifiers(event.modifierFlags)))
        }
        return shortcuts
    }

    /// The entry of `menu`, or of a menu inside it, that has this key.
    private func item(in menu: NSMenu, for event: NSEvent) -> NSMenuItem? {
        let shortcuts = Self.shortcuts(for: event)
        guard !shortcuts.isEmpty else { return nil }
        // A command's entry has the key the bindings give it.
        for shortcut in shortcuts {
            if let id = kernel.keyBindings.command(for: shortcut), kernel.keyBindings.menuShortcut(for: id) == shortcut,
                let item = Self.find(
                    in: menu, where: { MenuBuilder.command(of: $0) == id && !$0.keyEquivalent.isEmpty })
            {
                return item
            }
        }
        // The standard entries (Undo, and Cut, Copy, Paste where no plugin brought them) all have Cmd.
        guard event.modifierFlags.contains(.command) else { return nil }
        return Self.find(in: menu) { item in
            guard MenuBuilder.command(of: item) == nil, !item.keyEquivalent.isEmpty else { return false }
            var modifiers = KeyModifiers(item.keyEquivalentModifierMask)
            let key = item.keyEquivalent.lowercased()
            // A capital letter as the key means Shift.
            if key != item.keyEquivalent { modifiers.insert(.shift) }
            return shortcuts.contains(Shortcut(.character(key), modifiers))
        }
    }

    private static func find(in menu: NSMenu, where matches: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu {
                if let found = find(in: submenu, where: matches) { return found }
            } else if matches(item) {
                return item
            }
        }
        return nil
    }

    /// Whether one entry can be chosen now: asked of whoever would get its action, as the
    /// menu itself asks when it is opened.
    private func isEnabled(_ item: NSMenuItem) -> Bool {
        validations += 1
        guard let action = item.action, let responder = NSApp.target(forAction: action, to: item.target, from: item)
        else { return false }
        let object = responder as AnyObject
        if let validator = object as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = object as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }
}
