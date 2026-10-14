/// What the user entered in a form.
public struct FormValues: Sendable {
    /// The answer of one field.
    public enum Value: Equatable, Sendable {
        /// What a text field holds.
        case text(String)
        /// Whether a box is ticked.
        case flag(Bool)
        /// The chosen option or row.
        case index(Int)
    }

    /// The button the dialog was answered with, counted from the first.
    public var button: Int
    /// The answers by the fields' keys.
    public var values: [String: Value]

    /// Answers given as they are.
    public init(button: Int = 0, values: [String: Value] = [:]) {
        self.button = button
        self.values = values
    }

    /// The fields as they are before the user changes anything.
    public init(defaultsOf fields: [FormField], button: Int = 0) {
        self.button = button
        values = [:]
        for field in fields { values[field.key] = field.initialValue }
    }

    /// The text of the field `key`; empty when it holds none.
    public func text(_ key: String) -> String {
        if case .text(let text)? = values[key] {
            return text
        }
        return ""
    }

    /// Whether the box `key` is ticked; false when it is not a box.
    public func flag(_ key: String) -> Bool {
        if case .flag(let flag)? = values[key] {
            return flag
        }
        return false
    }

    /// The chosen option or row; -1 when nothing is chosen.
    public func index(_ key: String) -> Int {
        if case .index(let index)? = values[key] {
            return index
        }
        return -1
    }
}
