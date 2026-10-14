import Foundation

/// A key of a shortcut: a character (as it is on the user's keyboard layout) or a named key.
public enum Key: Hashable, Sendable {
    case character(String)
    /// F1…F12
    case function(Int)
    case returnKey, enter, tab, space, backspace, forwardDelete, insert
    case home, end, pageUp, pageDown, left, right, up, down
    case keypadPlus, keypadMinus, keypadMultiply, keypadDivide

    /// The text form of each named key, as `Shortcut.notation` writes it.
    internal static let names: [(Self, String)] = [
        (.returnKey, "return"), (.enter, "enter"), (.tab, "tab"), (.space, "space"), (.backspace, "backspace"),
        (.forwardDelete, "delete"), (.insert, "insert"), (.home, "home"), (.end, "end"), (.pageUp, "pageup"),
        (.pageDown, "pagedown"), (.left, "left"), (.right, "right"), (.up, "up"), (.down, "down"),
        (.keypadPlus, "num+"), (.keypadMinus, "num-"), (.keypadMultiply, "num*"), (.keypadDivide, "num/")
    ]
}
