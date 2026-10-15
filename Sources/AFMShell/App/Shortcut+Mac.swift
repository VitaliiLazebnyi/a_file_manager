public import AFMKernel
public import AppKit

/// The kernel's shortcuts as the Mac's key events and as the Mac writes them.
extension Shortcut {
    /// The signs of the named keys that are not written with a letter or a number.
    private static let keyNames: [Key: String] = [
        .returnKey: "↩", .enter: "⌤", .tab: "⇥", .space: "Space", .backspace: "⌫", .forwardDelete: "⌦", .insert: "Ins",
        .home: "↖", .end: "↘", .pageUp: "⇞", .pageDown: "⇟", .leftArrow: "←", .rightArrow: "→", .upArrow: "↑",
        .downArrow: "↓", .keypadPlus: "Num +", .keypadMinus: "Num −", .keypadMultiply: "Num ×",
        .keypadDivide: "Num ÷"
    ]
    /// The signs of the modifiers, in the order the Mac writes them.
    private static let modifierSigns: [(modifier: KeyModifiers, sign: String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
    ]

    /// The shortcut as the Mac writes it, for tooltips and the function-key bar: `⌃⇧F5`, `⌘C`.
    internal var displayText: String {
        let modifiers = Self.modifierSigns.filter { self.modifiers.contains($0.modifier) }.map(\.sign).joined()
        switch key {
        case .character(let character):
            return modifiers + character.uppercased()

        case .function(let number):
            return modifiers + "F\(number)"

        default:
            return modifiers + (Self.keyNames[key] ?? "?")
        }
    }

    /// Whether the main menu may own this shortcut.
    ///
    /// Plain typing keys (Return, Space, Backspace, arrows) must stay with text fields, so they
    /// are handled by the file list only.
    internal var isMenuSafe: Bool {
        guard key.menuEquivalent != nil else {
            return false
        }
        if case .function = key {
            return true
        }
        return !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// The shortcuts a key press can stand for: its named key, or the character it produces.
    internal static func candidates(for event: NSEvent) -> [Self] {
        let modifiers = KeyModifiers(event.modifierFlags)
        if let key = Key(keyCode: event.keyCode) {
            return [Self(key, modifiers)]
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
            return []
        }
        return [Self(.character(characters), modifiers)]
    }

    /// Whether a key press is this shortcut; for plugin windows that answer keys themselves.
    public func matches(_ event: NSEvent) -> Bool {
        Self.candidates(for: event).contains(self)
    }
}
