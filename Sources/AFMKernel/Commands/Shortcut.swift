/// A key with the modifiers held down with it, as commands are bound to them.
public struct Shortcut: Hashable, Sendable {
    /// The modifiers in the order the text form writes them, with their names there.
    private static let modifierNames: [(KeyModifiers, String)] = [
        (.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")
    ]

    /// The key pressed.
    public let key: Key
    /// The keys held down with it.
    public let modifiers: KeyModifiers

    /// The shortcut as text, as it is stored in the settings: `cmd+shift+c`, `f5`, `ctrl+tab`, `num+`.
    public var notation: String {
        Self.modifierNames.filter { modifiers.contains($0.0) }.map { $0.1 + "+" }.joined() + key.notation
    }

    /// `key` with `modifiers` held down.
    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Reads the text form; nil when it does not name a key.
    public init?(notation: String) {
        var rest = notation.lowercased()
        var held: KeyModifiers = []
        while let (modifier, name) = Self.modifierNames.first(where: { _, name in
            rest.hasPrefix(name + "+") && rest.count > name.count + 1
        }) {
            held.insert(modifier)
            rest.removeFirst(name.count + 1)
        }
        if let named = Key.named.first(where: { $0.notation == rest }) {
            self.init(named, held)
        } else if rest.count > 1, rest.hasPrefix("f"), let number = Int(rest.dropFirst()), (1...12).contains(number) {
            self.init(.function(number), held)
        } else if rest.count == 1 {
            self.init(.character(rest), held)
        } else {
            return nil
        }
    }

    /// Cmd+character, as most Mac shortcuts are.
    public static func cmd(_ character: String, _ extra: KeyModifiers = []) -> Self {
        Self(.character(character), extra.union(.command))
    }

    /// A function key.
    public static func f(_ number: Int, _ modifiers: KeyModifiers = []) -> Self {
        Self(.function(number), modifiers)
    }
}
