import Foundation

public struct KeyModifiers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// A key of a shortcut: a character (as it is on the user's keyboard layout) or a named key.
public enum Key: Hashable {
    case character(String)
    /// F1…F12
    case function(Int)
    case returnKey, enter, tab, space, backspace, forwardDelete, insert
    case home, end, pageUp, pageDown, left, right, up, down
    case keypadPlus, keypadMinus, keypadMultiply, keypadDivide

    fileprivate static let names: [(Key, String)] = [
        (.returnKey, "return"), (.enter, "enter"), (.tab, "tab"), (.space, "space"), (.backspace, "backspace"),
        (.forwardDelete, "delete"), (.insert, "insert"), (.home, "home"), (.end, "end"), (.pageUp, "pageup"),
        (.pageDown, "pagedown"), (.left, "left"), (.right, "right"), (.up, "up"), (.down, "down"),
        (.keypadPlus, "num+"), (.keypadMinus, "num-"), (.keypadMultiply, "num*"), (.keypadDivide, "num/"),
    ]
}

public struct Shortcut: Hashable {
    public let key: Key
    public let modifiers: KeyModifiers

    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Cmd+character, as most Mac shortcuts are.
    public static func cmd(_ character: String, _ extra: KeyModifiers = []) -> Shortcut {
        Shortcut(.character(character), extra.union(.command))
    }

    /// A function key.
    public static func f(_ number: Int, _ modifiers: KeyModifiers = []) -> Shortcut {
        Shortcut(.function(number), modifiers)
    }

    private static let modifierNames: [(KeyModifiers, String)] = [(.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")]

    /// The shortcut as text, as it is stored in the settings: `cmd+shift+c`, `f5`, `ctrl+tab`, `num+`.
    public var notation: String {
        let prefix = Shortcut.modifierNames.filter { modifiers.contains($0.0) }.map { $0.1 + "+" }.joined()
        switch key {
        case .character(let character): return prefix + character
        case .function(let number): return prefix + "f\(number)"
        default: return prefix + (Key.names.first { $0.0 == key }?.1 ?? "?")
        }
    }

    /// Reads the text form; nil when it does not name a key.
    public init?(notation: String) {
        var rest = notation.lowercased()
        var modifiers: KeyModifiers = []
        while let (modifier, name) = Shortcut.modifierNames.first(where: { rest.hasPrefix($0.1 + "+") && rest.count > $0.1.count + 1 }) {
            modifiers.insert(modifier)
            rest.removeFirst(name.count + 1)
        }
        if let named = Key.names.first(where: { $0.1 == rest })?.0 {
            self.init(named, modifiers)
        } else if rest.count > 1, rest.hasPrefix("f"), let number = Int(rest.dropFirst()), (1...12).contains(number) {
            self.init(.function(number), modifiers)
        } else if rest.count == 1 {
            self.init(.character(rest), modifiers)
        } else {
            return nil
        }
    }
}
