import Foundation

/// One row of a dialog a plugin asks the user to fill in (`UserInteraction.form`). A plugin
/// describes what it wants to know; how the dialog looks is up to whoever shows it.
public struct FormField: Sendable {
    public enum Kind: Sendable {
        /// One line of text, pre-filled.
        case text(String)
        /// One line whose characters are not shown (a password).
        case secureText
        /// Several lines of text, pre-filled.
        case multilineText(String)
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
    public let label: String
    public let kind: Kind

    public init(_ key: String, _ label: String, _ kind: Kind) {
        self.key = key
        self.label = label
        self.kind = kind
    }

    public static func text(_ key: String, _ label: String, _ value: String = "") -> Self {
        Self(key, label, .text(value))
    }
    public static func password(_ key: String, _ label: String) -> Self { Self(key, label, .secureText) }
    public static func lines(_ key: String, _ label: String, _ value: String = "") -> Self {
        Self(key, label, .multilineText(value))
    }
    public static func checkbox(_ key: String, _ label: String, _ isOn: Bool = false) -> Self {
        Self(key, label, .checkbox(isOn))
    }
    public static func choice(_ key: String, _ label: String, _ options: [String], selected: Int = 0) -> Self {
        Self(key, label, .choice(options, selected: selected))
    }
    public static func list(_ key: String, _ label: String, _ rows: [String], selected: Int = 0) -> Self {
        Self(key, label, .list(rows, selected: selected))
    }
    public static func note(_ text: String) -> Self { Self("", text, .note) }

    /// What the field holds before the user changes anything; nil for a note.
    public var initialValue: FormValues.Value? {
        switch kind {
        case .text(let text), .multilineText(let text): return .text(text)
        case .secureText: return .text("")
        case .checkbox(let isOn): return .flag(isOn)
        case .choice(_, let selected), .list(_, let selected): return .index(selected)
        case .note: return nil
        }
    }
}
