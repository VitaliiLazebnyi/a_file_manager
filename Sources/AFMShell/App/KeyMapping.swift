import AFMKernel
import AppKit

/// Translates between the kernel's shortcuts and the Mac's key events and menu keys.
extension Key {
    private static let keyCodes: [Key: UInt16] = [
        .returnKey: 36, .enter: 76, .tab: 48, .space: 49, .backspace: 51, .forwardDelete: 117, .insert: 114,
        .home: 115, .end: 119, .pageUp: 116, .pageDown: 121, .left: 123, .right: 124, .down: 125, .up: 126,
        .keypadPlus: 69, .keypadMinus: 78, .keypadMultiply: 67, .keypadDivide: 75,
    ]
    private static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    private static let namedKeys: [UInt16: Key] = {
        var keys = Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })
        for (index, code) in functionKeyCodes.enumerated() { keys[code] = .function(index + 1) }
        return keys
    }()

    /// The named key a physical key stands for; nil for keys that produce characters.
    init?(keyCode: UInt16) {
        guard let key = Key.namedKeys[keyCode] else { return nil }
        self = key
    }

    /// The key as a menu key equivalent; nil for keys a menu cannot show (the numeric keypad).
    var menuEquivalent: String? {
        func special(_ value: Int) -> String { String(UnicodeScalar(UInt32(value))!) }
        switch self {
        case .character(let character): return character
        case .function(let number): return special(NSF1FunctionKey + number - 1)
        case .returnKey: return "\r"
        case .tab: return "\t"
        case .backspace: return "\u{8}"
        case .forwardDelete: return special(NSDeleteFunctionKey)
        case .home: return special(NSHomeFunctionKey)
        case .end: return special(NSEndFunctionKey)
        case .pageUp: return special(NSPageUpFunctionKey)
        case .pageDown: return special(NSPageDownFunctionKey)
        case .left: return special(NSLeftArrowFunctionKey)
        case .right: return special(NSRightArrowFunctionKey)
        case .up: return special(NSUpArrowFunctionKey)
        case .down: return special(NSDownArrowFunctionKey)
        default: return nil
        }
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }
}

extension Shortcut {
    /// The shortcuts a key press can stand for: its named key, or the character it produces.
    static func candidates(for event: NSEvent) -> [Shortcut] {
        let modifiers = KeyModifiers(event.modifierFlags)
        if let key = Key(keyCode: event.keyCode) { return [Shortcut(key, modifiers)] }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else { return [] }
        return [Shortcut(.character(characters), modifiers)]
    }

    /// Whether a key press is this shortcut.
    public func matches(_ event: NSEvent) -> Bool {
        Shortcut.candidates(for: event).contains(self)
    }

    /// The shortcut as the Mac writes it, for tooltips and the function-key bar: `⌃⇧F5`, `⌘C`.
    var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): return text + character.uppercased()
        case .function(let number): return text + "F\(number)"
        default: return text + (Shortcut.keyNames[key] ?? "?")
        }
    }

    private static let keyNames: [Key: String] = [
        .returnKey: "↩", .enter: "⌤", .tab: "⇥", .space: "Space", .backspace: "⌫", .forwardDelete: "⌦", .insert: "Ins",
        .home: "↖", .end: "↘", .pageUp: "⇞", .pageDown: "⇟", .left: "←", .right: "→", .up: "↑", .down: "↓",
        .keypadPlus: "Num +", .keypadMinus: "Num −", .keypadMultiply: "Num ×", .keypadDivide: "Num ÷",
    ]

    /// Whether the main menu may own this shortcut. Plain typing keys (Return, Space, Backspace,
    /// arrows) must stay with text fields, so they are handled by the file list only.
    var isMenuSafe: Bool {
        guard key.menuEquivalent != nil else { return false }
        if case .function = key { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option])
    }
}

extension KeyBindings {
    /// The command a key press is bound to. For the file list and for plugin windows that want
    /// to answer to the same keys.
    public func command(for event: NSEvent) -> CommandID? {
        Shortcut.candidates(for: event).lazy.compactMap { self.command(for: $0) }.first
    }

    /// The key shown next to a command in a menu.
    func menuShortcut(for command: CommandID) -> Shortcut? {
        shortcuts(for: command).first(where: \.isMenuSafe)
    }
}

extension CommandRegistry {
    func command(with role: EditingRole) -> CommandID? {
        all.first { $0.editingRole == role }?.id
    }
}
