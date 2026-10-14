/// One row of a dialog a plugin asks the user to fill in (`UserInteraction.form`).
///
/// A plugin describes what it wants to know; how the dialog looks is up to whoever shows it.
public struct FormField: Sendable {
    /// What the row asks for, with what it holds before the user changes anything.
    public enum Kind: Sendable {
        /// One line of text, pre-filled.
        case text(String)
        /// One line whose characters are not shown (a password).
        case secureText
        /// Several lines of text, pre-filled.
        case multilineText(String)
        /// A box to tick, ticked or not.
        case checkbox(Bool)
        /// One of a few options, shown as a pop-up button.
        case choice([String], selected: Int)
        /// One row of a longer list; a double click on a row answers the dialog with its
        /// first button.
        case list([String], selected: Int)
        /// Nothing to fill in: the label is shown as a line of explanation.
        case note
    }

    /// The name the answer is found under in `FormValues`.
    public let key: String
    /// What the dialog shows next to the field (for a note: the text itself).
    public let label: String
    /// What the field asks for.
    public let kind: Kind

    /// What the field holds before the user changes anything; nil for a note.
    public var initialValue: FormValues.Value? {
        switch kind {
        case .text(let text), .multilineText(let text):
            return .text(text)

        case .secureText:
            return .text("")

        case .checkbox(let isOn):
            return .flag(isOn)

        case .choice(_, let selected), .list(_, let selected):
            return .index(selected)

        case .note:
            return nil
        }
    }

    /// A field whose answer is found under `key`, shown as `label`.
    public init(_ key: String, _ label: String, _ kind: Kind) {
        self.key = key
        self.label = label
        self.kind = kind
    }

    /// One line of text, pre-filled with `value`.
    public static func text(_ key: String, _ label: String, _ value: String = "") -> Self {
        Self(key, label, .text(value))
    }

    /// One line whose characters are not shown.
    public static func password(_ key: String, _ label: String) -> Self { Self(key, label, .secureText) }

    /// Several lines of text, pre-filled with `value`.
    public static func lines(_ key: String, _ label: String, _ value: String = "") -> Self {
        Self(key, label, .multilineText(value))
    }

    /// A box to tick, ticked when `isOn`.
    public static func checkbox(_ key: String, _ label: String, _ isOn: Bool = false) -> Self {
        Self(key, label, .checkbox(isOn))
    }

    /// A pop-up button with `options`, the one at `selected` chosen.
    public static func choice(_ key: String, _ label: String, _ options: [String], selected: Int = 0) -> Self {
        Self(key, label, .choice(options, selected: selected))
    }

    /// A list of `rows`, the one at `selected` chosen.
    public static func list(_ key: String, _ label: String, _ rows: [String], selected: Int = 0) -> Self {
        Self(key, label, .list(rows, selected: selected))
    }

    /// A line of explanation that asks nothing.
    public static func note(_ text: String) -> Self { Self("", text, .note) }
}
