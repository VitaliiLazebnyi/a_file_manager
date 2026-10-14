import Foundation

/// A key of a shortcut: a character (as it is on the user's keyboard layout) or a named key.
public enum Key: Hashable, Sendable {
    /// Backspace, which deletes to the left.
    case backspace
    /// A character as the user's keyboard layout types it, lowercase.
    case character(String)
    /// The arrow that moves down.
    case downArrow
    /// End.
    case end
    /// Enter on the numeric keypad.
    case enter
    /// Forward delete, which deletes to the right.
    case forwardDelete
    /// A function key, F1…F12.
    case function(Int)
    /// Home.
    case home
    /// Insert (Help on Mac keyboards).
    case insert
    /// The slash on the numeric keypad.
    case keypadDivide
    /// The minus on the numeric keypad.
    case keypadMinus
    /// The star on the numeric keypad.
    case keypadMultiply
    /// The plus on the numeric keypad.
    case keypadPlus
    /// The arrow that moves left.
    case leftArrow
    /// Page Down.
    case pageDown
    /// Page Up.
    case pageUp
    /// Return, the main key that ends a line.
    case returnKey
    /// The arrow that moves right.
    case rightArrow
    /// The space bar.
    case space
    /// Tab.
    case tab
    /// The arrow that moves up.
    case upArrow

    /// The text form of each named key, as `Shortcut.notation` writes it.
    internal static let names: [(Self, String)] = [
        (.returnKey, "return"), (.enter, "enter"), (.tab, "tab"), (.space, "space"), (.backspace, "backspace"),
        (.forwardDelete, "delete"), (.insert, "insert"), (.home, "home"), (.end, "end"), (.pageUp, "pageup"),
        (.pageDown, "pagedown"), (.leftArrow, "left"), (.rightArrow, "right"), (.upArrow, "up"), (.downArrow, "down"),
        (.keypadPlus, "num+"), (.keypadMinus, "num-"), (.keypadMultiply, "num*"), (.keypadDivide, "num/")
    ]
}
