import AFMKernel

/// The Mac's names and symbols of the keys, as the editors and the keyboard help show them.
extension Key {
    /// How the key is written on the Mac: `C`, `F5`, `↩`.
    internal var macSymbol: String {
        switch self {
        case .character(let character):
            character.uppercased()

        case .function(let number):
            "F\(number)"

        case .returnKey:
            "↩"

        case .enter:
            "⌤"

        case .tab:
            "⇥"

        case .space:
            "Space"

        case .backspace:
            "⌫"

        case .forwardDelete:
            "⌦"

        case .insert:
            "Insert"

        case .home:
            "↖"

        case .end:
            "↘"

        case .pageUp:
            "⇞"

        case .pageDown:
            "⇟"

        case .leftArrow:
            "←"

        case .rightArrow:
            "→"

        case .upArrow:
            "↑"

        case .downArrow:
            "↓"

        case .keypadPlus:
            "Num +"

        case .keypadMinus:
            "Num −"

        case .keypadMultiply:
            "Num *"

        case .keypadDivide:
            "Num /"
        }
    }
}
