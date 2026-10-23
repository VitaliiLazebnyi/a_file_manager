import AFMKernel
import Foundation

/// Shortcuts as the user reads and presses them.
internal enum ShortcutText {
    /// The keys that are written by a name of their own rather than by a character or a number.
    internal static let namedKeys: [Key] = [
        .returnKey, .enter, .tab, .space, .backspace, .forwardDelete, .insert, .home, .end, .pageUp, .pageDown,
        .leftArrow, .rightArrow, .upArrow, .downArrow, .keypadPlus, .keypadMinus, .keypadMultiply, .keypadDivide
    ]

    private static let namedKeyCodes: [UInt16: Key] = {
        var keys: [UInt16: Key] = [
            36: .returnKey, 76: .enter, 48: .tab, 49: .space, 51: .backspace, 117: .forwardDelete, 114: .insert,
            115: .home, 119: .end, 116: .pageUp, 121: .pageDown, 123: .leftArrow, 124: .rightArrow, 125: .downArrow,
            126: .upArrow,
            69: .keypadPlus, 78: .keypadMinus, 67: .keypadMultiply, 75: .keypadDivide
        ]
        for (index, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() {
            keys[UInt16(code)] = .function(index + 1)
        }
        return keys
    }()

    /// The Mac's way of writing a shortcut: `⌃⌥⇧⌘C`, `⇧F5`.
    internal static func display(_ shortcut: Shortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        return text + shortcut.key.macSymbol
    }

    /// Several shortcuts the Mac's way, separated by commas.
    internal static func display(_ shortcuts: [Shortcut]) -> String {
        shortcuts.map(display).joined(separator: ", ")
    }

    /// Reads what the user typed into a shortcut field: the stored notation (`ctrl+shift+n`)
    /// or the Mac's symbols (`⌃⇧N`).
    ///
    /// Nil when it names no key.
    internal static func parse(_ text: String) -> Shortcut? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            return nil
        }
        var modifiers: KeyModifiers = []
        let symbols: [Character: KeyModifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        while rest.count > 1, let first = rest.first, let modifier = symbols[first] {
            modifiers.insert(modifier)
            rest.removeFirst()
        }
        if let named = namedKeys.first(where: { $0.macSymbol.lowercased() == rest.lowercased() }) {
            return Shortcut(named, modifiers)
        }
        guard let shortcut = Shortcut(notation: rest) else {
            return nil
        }
        return Shortcut(shortcut.key, shortcut.modifiers.union(modifiers))
    }

    /// The shortcut a key press stands for, by the rule the window shell matches key presses
    /// with: a named key by its key code, otherwise the character the key produces without
    /// its modifiers.
    ///
    /// Nil for a press that produces nothing.
    internal static func shortcut(keyCode: UInt16, characters: String?, modifiers: KeyModifiers) -> Shortcut? {
        if let key = namedKeyCodes[keyCode] {
            return Shortcut(key, modifiers)
        }
        guard let typed = characters?.lowercased(), !typed.isEmpty else {
            return nil
        }
        return Shortcut(.character(typed), modifiers)
    }
}
