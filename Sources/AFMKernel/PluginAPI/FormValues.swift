import Foundation

/// What the user entered in a form.
public struct FormValues: Sendable {
    public enum Value: Equatable, Sendable {
        case text(String)
        case flag(Bool)
        case index(Int)
    }

    /// The button the dialog was answered with, counted from the first.
    public var button: Int
    public var values: [String: Value]

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

    public func text(_ key: String) -> String {
        if case .text(let text)? = values[key] { return text }
        return ""
    }

    public func flag(_ key: String) -> Bool {
        if case .flag(let flag)? = values[key] { return flag }
        return false
    }

    /// The chosen option or row; -1 when nothing is chosen.
    public func index(_ key: String) -> Int {
        if case .index(let index)? = values[key] { return index }
        return -1
    }
}
