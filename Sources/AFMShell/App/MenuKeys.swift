import AFMKernel
import AppKit

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
@MainActor
internal final class MenuKeys: NSObject, NSMenuDelegate {
    /// The characters of the keys of an American keyboard, by key code.
    ///
    /// What a key with Cmd means while the keyboard writes another script (Cmd+C is Cmd+C on a
    /// Russian keyboard too).
    private static let plainKeys: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
        39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`"
    ]

    /// How often a key was looked up; for checks.
    internal private(set) var lookups = 0
    /// How many entries were checked for keys and for menus about to be shown; for checks.
    internal private(set) var validations = 0
    /// The kernel whose key bindings decide which entry a key belongs to.
    private let kernel: Kernel
    /// The entry the last key belonged to, until its action has run.
    private var matched: NSMenuItem?

    /// An object that answers with the key bindings of `kernel`.
    internal init(kernel: Kernel) {
        self.kernel = kernel
    }

    /// The shortcuts a key press can stand for.
    ///
    /// As the file lists read keys, and for a keyboard that writes no Latin letters also the
    /// key's Latin meaning.
    internal static func shortcuts(for event: NSEvent) -> [Shortcut] {
        var shortcuts = Shortcut.candidates(for: event)
        if Key(keyCode: event.keyCode) == nil, let typed = event.charactersIgnoringModifiers,
            typed.unicodeScalars.contains(where: { $0.value >= 0x80 }),
            let plain = plainKeys[event.keyCode]
        {
            shortcuts.append(Shortcut(.character(plain), KeyModifiers(event.modifierFlags)))
        }
        return shortcuts
    }

    /// The first entry of `menu`, or of a menu inside it, for which `matches` is true.
    private static func find(in menu: NSMenu, where matches: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu {
                if let found = find(in: submenu, where: matches) {
                    return found
                }
            } else if matches(item) {
                return item
            }
        }
        return nil
    }

    /// Makes this object answer for a menu and all menus inside it.
    internal func answer(for menu: NSMenu) {
        menu.delegate = self
        menu.autoenablesItems = false
        for item in menu.items {
            item.submenu.map(answer(for:))
        }
    }

    /// The menu is about to be shown: its entries follow their commands.
    ///
    /// As an automatically enabling menu's would. (Not called for a key: `menuHasKeyEquivalent`
    /// answers those.)
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && !item.hasSubmenu {
            let isEnabled = isEnabled(item)
            if item.isEnabled != isEnabled {
                item.isEnabled = isEnabled
            }
        }
    }

    /// Whether the key of `event` belongs to an entry of `menu` that can be chosen now.
    ///
    /// If so, the entry is named as what is to run (`performMatched`), through `target` and
    /// `action`.
    internal func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        lookups += 1
        guard event.type == .keyDown, let item = item(in: menu, for: event) else {
            return false
        }
        // The entry shows what was found out about it, also to the menu's own search for the
        // key, which follows when this says no.
        let isEnabled = isEnabled(item)
        if item.isEnabled != isEnabled {
            item.isEnabled = isEnabled
        }
        guard isEnabled else {
            return false
        }
        matched = item
        target.pointee = self
        action.pointee = #selector(performMatched(_:))
        return true
    }

    /// Runs the action of the entry the key belonged to, with the entry as its sender.
    ///
    /// The way choosing it from the menu would.
    @objc
    internal func performMatched(_: Any?) {
        guard let item = matched else {
            return
        }
        matched = nil
        if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    /// The entry of `menu`, or of a menu inside it, that has the key of `event`.
    private func item(in menu: NSMenu, for event: NSEvent) -> NSMenuItem? {
        let shortcuts = Self.shortcuts(for: event)
        // A command's entry has the key the bindings give it.
        for shortcut in shortcuts {
            guard let id = kernel.keyBindings.command(for: shortcut),
                kernel.keyBindings.menuShortcut(for: id) == shortcut
            else {
                continue
            }
            let item = Self.find(in: menu) { MenuBuilder.command(of: $0) == id && !$0.keyEquivalent.isEmpty }
            if let item {
                return item
            }
        }
        // The standard entries (Undo, and Cut, Copy, Paste where no plugin brought them) all have Cmd.
        guard event.modifierFlags.contains(.command) else {
            return nil
        }
        return Self.find(in: menu) { item in
            guard MenuBuilder.command(of: item) == nil, !item.keyEquivalent.isEmpty else {
                return false
            }
            var modifiers = KeyModifiers(item.keyEquivalentModifierMask)
            let key = item.keyEquivalent.lowercased()
            // A capital letter as the key means Shift.
            if key != item.keyEquivalent {
                modifiers.insert(.shift)
            }
            return shortcuts.contains(Shortcut(.character(key), modifiers))
        }
    }

    /// Whether one entry can be chosen now.
    ///
    /// Asked of whoever would get its action, as the menu itself asks when it is opened.
    private func isEnabled(_ item: NSMenuItem) -> Bool {
        validations += 1
        guard let action = item.action, let responder = NSApp.target(forAction: action, to: item.target, from: item)
        else {
            return false
        }
        let object = responder as AnyObject
        if let validator = object as? (any NSMenuItemValidation) {
            return validator.validateMenuItem(item)
        }
        if let validator = object as? (any NSUserInterfaceValidations) {
            return validator.validateUserInterfaceItem(item)
        }
        return true
    }
}
