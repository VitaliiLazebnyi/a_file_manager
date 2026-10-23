import AFMKernel

/// Shortcuts as the Lister's menus show them.
extension Shortcut {
    /// The shortcut as a menu shows it: `⌃⇧C`, `F7`, `Num +`.
    internal var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character):
            return text + character.uppercased()

        case .function(let number):
            return text + "F\(number)"

        case .returnKey, .enter:
            return text + "↩"

        case .keypadPlus:
            return text + "Num +"

        case .keypadMinus:
            return text + "Num −"

        case .leftArrow:
            return text + "←"

        case .rightArrow:
            return text + "→"

        case .upArrow:
            return text + "↑"

        case .downArrow:
            return text + "↓"

        default:
            return text + notation
        }
    }
}
