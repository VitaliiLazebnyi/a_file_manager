public import AFMKernel

/// The rule list of the Plugins tab (spec 09 › Plugins tab).
public struct FieldRules: Codable, Equatable, Sendable {
    /// Switches the whole list on or off without clearing it.
    public var isEnabled: Bool
    /// AND (all rules match) or OR (any rule matches).
    public var matchAll: Bool
    /// The rows of the list, in order.
    public var rules: [FieldRule]

    /// Whether the list takes part in a search: switched on and not empty.
    public var isActive: Bool { isEnabled && !rules.isEmpty }

    /// The first rule that cannot be used because its regular expression is none; the search is
    /// not started with such a list.
    public var unusableRule: FieldRule? { isActive ? rules.first { !$0.isUsable } : nil }

    /// A list of `rules`, by default switched off, all of which must match.
    public init(isEnabled: Bool = false, matchAll: Bool = true, rules: [FieldRule] = []) {
        self.isEnabled = isEnabled
        self.matchAll = matchAll
        self.rules = rules
    }

    /// Whether `item` passes the list; a rule whose field no longer exists (its plugin is gone) never matches.
    public func matches(_ item: FileItem, fields: [String: SearchField]) -> Bool {
        prepared(trip: nil).matches(item, fields: fields) { false }
    }

    /// The rules with their regular expressions compiled once, for testing many files from
    /// several threads; `trip` counts the expressions that ran out of time (nil: none counts).
    internal func prepared(trip: RegexTrip?) -> PreparedFieldRules {
        PreparedFieldRules(self, trip: trip)
    }
}
