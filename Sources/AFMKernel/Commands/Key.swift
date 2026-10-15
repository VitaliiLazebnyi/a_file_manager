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

    /// The keys with a name of their own, as opposed to characters and function keys.
    internal static let named: [Self] = [
        .returnKey, .enter, .tab, .space, .backspace, .forwardDelete, .insert, .home, .end, .pageUp, .pageDown,
        .leftArrow, .rightArrow, .upArrow, .downArrow, .keypadPlus, .keypadMinus, .keypadMultiply, .keypadDivide
    ]

    /// The key as `Shortcut.notation` writes it: the character itself, `f5`, or the key's name
    /// (`return`, `pageup`, `num+`).
    internal var notation: String {
        switch self {
        case .backspace:
            "backspace"

        case .character(let character):
            character

        case .downArrow:
            "down"

        case .end:
            "end"

        case .enter:
            "enter"

        case .forwardDelete:
            "delete"

        case .function(let number):
            "f\(number)"

        case .home:
            "home"

        case .insert:
            "insert"

        case .keypadDivide:
            "num/"

        case .keypadMinus:
            "num-"

        case .keypadMultiply:
            "num*"

        case .keypadPlus:
            "num+"

        case .leftArrow:
            "left"

        case .pageDown:
            "pagedown"

        case .pageUp:
            "pageup"

        case .returnKey:
            "return"

        case .rightArrow:
            "right"

        case .space:
            "space"

        case .tab:
            "tab"

        case .upArrow:
            "up"
        }
    }
}
