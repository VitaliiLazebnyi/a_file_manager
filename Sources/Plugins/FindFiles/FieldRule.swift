import Foundation

/// One row of the Plugins tab: field, operator, value.
public struct FieldRule: Codable, Equatable, Sendable {
    /// How a field's text is compared with the value, in the order of the menu; stored by its number.
    public enum Operator: Int, Codable, CaseIterable, Sendable {
        /// The text holds the value, case ignored.
        case contains = 0
        /// The text does not hold the value, case ignored.
        case notContains = 1
        /// The text holds the value as written.
        case containsCase = 2
        /// The text does not hold the value as written.
        case notContainsCase = 3
        /// The text is the value, case ignored.
        case equals = 4
        /// The text is not the value, case ignored.
        case notEquals = 5
        /// The text is the value as written.
        case equalsCase = 6
        /// The text is not the value as written.
        case notEqualsCase = 7
        /// The regular expression of the value matches the text, case ignored.
        case regex = 8
        /// The regular expression of the value does not match the text.
        case notRegex = 9
        /// The text comes after the value (as numbers when both are numbers).
        case greater = 10
        /// The text comes before the value.
        case less = 11
        /// The text comes after the value or is equal to it.
        case greaterOrEqual = 12
        /// The text comes before the value or is equal to it.
        case lessOrEqual = 13

        /// The title in the menu.
        public var title: String {
            [
                "contains", "!contains", "cont.(case)", "!cont.(case)", "=", "!=", "=(case)", "!=(case)", "regex",
                "!regex", ">", "<", ">=", "<="
            ][rawValue]
        }
    }

    /// The `id` of the field tested (`SearchField.id`).
    public var field: String
    /// How the field's text is compared.
    public var comparison: Operator
    /// What the field's text is compared with.
    public var value: String

    /// Whether the rule's operator reads its value as a regular expression.
    public var usesRegex: Bool { comparison == .regex || comparison == .notRegex }

    /// False for a regex rule whose value is no regular expression: it can never be judged.
    public var isUsable: Bool { !usesRegex || compiledExpression() != nil }

    /// Whether the operator is the "not" form of another: it holds where that one does not.
    private var isNegated: Bool {
        [.notContains, .notContainsCase, .notEquals, .notEqualsCase, .notRegex].contains(comparison)
    }

    /// A rule that compares the text of `field` with `value` by `comparison`.
    public init(_ field: String, _ comparison: Operator, _ value: String) {
        self.field = field
        self.comparison = comparison
        self.value = value
    }

    /// The number a text stands for, with digit grouping (commas, spaces) left out; nil when it is none.
    internal static func number(_ text: String) -> Double? {
        Double(text.filter { $0 != "," && $0 != " " && $0 != "\u{a0}" })
    }

    /// Tests a field's text.
    ///
    /// The ordering operators compare as numbers when both sides are numbers (digit grouping is
    /// ignored), otherwise as text without regard to case.
    public func matches(_ text: String) -> Bool {
        matches(text, expression: compiledExpression(), trip: nil) { false }
    }

    /// The value as a regular expression; nil when the operator is no regex one or the value is not one.
    internal func compiledExpression() -> NSRegularExpression? {
        usesRegex ? try? NSRegularExpression(pattern: value, options: .caseInsensitive) : nil
    }

    /// The same with the regular expression compiled once (`compiledExpression()`); a run that
    /// takes the expression too long, or is cancelled, finds no match.
    ///
    /// A value that is no expression never matches `regex` and always matches `!regex`.
    internal func matches(
        _ text: String,
        expression: NSRegularExpression?,
        trip: RegexTrip?,
        cancelled: () -> Bool
    ) -> Bool {
        let found: Bool
        switch comparison {
        case .contains, .notContains:
            found = text.range(of: value, options: .caseInsensitive) != nil

        case .containsCase, .notContainsCase:
            found = text.contains(value)

        case .equals, .notEquals:
            found = text.caseInsensitiveCompare(value) == .orderedSame

        case .equalsCase, .notEqualsCase:
            found = text == value

        case .regex, .notRegex:
            if let expression {
                found = FindRegex.matches(expression, in: text, trip: trip, cancelled: cancelled)
            } else {
                found = false
            }

        case .greater, .less, .greaterOrEqual, .lessOrEqual:
            return isInOrder(text)
        }
        return found != isNegated
    }

    /// Whether `text` stands to the value as an ordering operator asks: as numbers when both are numbers,
    /// otherwise as text without regard to case; an empty text never does.
    private func isInOrder(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        let order: ComparisonResult
        if let left = Self.number(text), let right = Self.number(value) {
            order = left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
        } else {
            order = text.caseInsensitiveCompare(value)
        }
        switch comparison {
        case .greater:
            return order == .orderedDescending

        case .less:
            return order == .orderedAscending

        case .greaterOrEqual:
            return order != .orderedAscending

        default:
            return order != .orderedDescending
        }
    }
}
