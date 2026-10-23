import AFMKernel
import Foundation

/// `FieldRules` with the expressions compiled; immutable, safe to use from several threads.
internal struct PreparedFieldRules {
    private let rules: FieldRules
    private let expressions: [NSRegularExpression?]
    private let trip: RegexTrip?

    /// `rules` with their expressions compiled; `trip` counts the ones that run out of time.
    internal init(_ rules: FieldRules, trip: RegexTrip?) {
        self.rules = rules
        self.trip = trip
        expressions = rules.rules.map { $0.compiledExpression() }
    }

    /// Whether `item` passes the list, its fields read through `fields`; `cancelled` ends the work early,
    /// and a cancelled test does not pass.
    internal func matches(_ item: FileItem, fields: [String: SearchField], cancelled: () -> Bool) -> Bool {
        guard rules.isActive else {
            return true
        }
        func holds(_ index: Int) -> Bool {
            let rule = rules.rules[index]
            guard !cancelled() else {
                return false
            }
            return fields[rule.field]
                .map { field in
                    rule.matches(field.value(item), expression: expressions[index], trip: trip, cancelled: cancelled)
                } ?? false
        }
        // Any rule (the rarer choice), or all of them.
        return !rules.matchAll ? rules.rules.indices.contains(where: holds) : rules.rules.indices.allSatisfy(holds)
    }
}
