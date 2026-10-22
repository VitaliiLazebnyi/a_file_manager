import AFMContracts
public import AFMKernel
public import Foundation

/// A state of the Advanced tab's attribute boxes: must be set, must not be set, or either.
public enum TriState: Int, Codable, Sendable {
    case any, yes, no

    func accepts(_ value: Bool) -> Bool {
        self == .any || (self == .yes) == value
    }
}

/// "Not older than 3 days" (spec 09 › Advanced tab).
public struct Age: Codable, Equatable, Sendable {
    public enum Unit: Int, Codable, CaseIterable, Sendable {
        case minutes, hours, days, weeks, months, years

        public var title: String { ["minute(s)", "hour(s)", "day(s)", "week(s)", "month(s)", "year(s)"][rawValue] }
    }

    public var count: Int
    public var unit: Unit

    public init(_ count: Int, _ unit: Unit) {
        self.count = count
        self.unit = unit
    }

    /// The most of any unit that is calculated with: a count typed or loaded beyond this (a
    /// saved search can hold any number) is held to it instead of overflowing.
    public static let largestCount = 1_000_000

    /// The moment that lies this far before `now`.
    ///
    /// For days and longer units it is midnight of that day, not the current time of day. A count
    /// beyond what the calendar can reach gives the earliest moment there is.
    public func cutoff(before now: Date, calendar: Calendar = .current) -> Date {
        let count = min(max(count, 0), Self.largestCount)
        var step = DateComponents()
        switch unit {
        case .minutes:
            step.minute = -count

        case .hours:
            step.hour = -count

        case .days:
            step.day = -count

        case .weeks:
            step.day = -7 * count

        case .months:
            step.month = -count

        case .years:
            step.year = -count
        }
        guard let moment = calendar.date(byAdding: step, to: now) else {
            return .distantPast
        }
        return unit.rawValue >= Unit.days.rawValue ? calendar.startOfDay(for: moment) : moment
    }
}

/// "File size > 1.5 Mbytes" (spec 09 › Advanced tab).
public struct SizeRule: Codable, Equatable, Sendable {
    public enum Comparison: Int, Codable, CaseIterable, Sendable {
        case equal, greater, less

        public var title: String { ["=", ">", "<"][rawValue] }
    }

    public enum Unit: Int, Codable, CaseIterable, Sendable {
        case bytes, kilobytes, megabytes, gigabytes

        public var title: String { ["bytes", "kbytes", "Mbytes", "Gbytes"][rawValue] }
        public var factor: Double { pow(1_024, Double(rawValue)) }
    }

    public var comparison: Comparison
    /// Fractions are allowed: 0.1 Gbytes.
    public var value: Double
    public var unit: Unit

    public init(_ comparison: Comparison, _ value: Double, _ unit: Unit = .bytes) {
        self.comparison = comparison
        self.value = value
        self.unit = unit
    }

    /// `=` in a unit larger than bytes takes every size that shows as this figure: `= 2 kbytes`
    /// finds 2,048 to 3,071 bytes.
    public func matches(_ size: Int64) -> Bool {
        let bytes = self.bytes
        switch comparison {
        case .greater:
            return size > bytes

        case .less:
            return size < bytes

        case .equal:
            return unit == .bytes ? size == bytes : (bytes..<upperBytes).contains(size)
        }
    }

    /// The figure in bytes; an absurd value (a huge number, not a number) is held to what a
    /// size can be, not trapped on.
    public var bytes: Int64 {
        let exact = (value * unit.factor).rounded()
        guard !exact.isNaN else {
            return 0
        }
        return exact >= 9.2e18 ? Int64.max : exact <= -9.2e18 ? Int64.min : Int64(exact)
    }

    /// The first size above the figure that still shows as it (`= 2 kbytes` ends at 3,072).
    public var upperBytes: Int64 {
        let step = unit == .bytes ? 1 : Int64(unit.factor)
        let (end, overflow) = bytes.addingReportingOverflow(step)
        return overflow ? Int64.max : end
    }
}

/// The criteria of the Advanced tab except the duplicate finder; all that are set must hold
/// (spec 09 › Advanced tab).
///
/// The Windows attributes are replaced by what a Mac's files have.
public struct FileCriteria: Codable, Equatable, Sendable {
    /// "Date between": either bound may be missing. `dateTo` is the last moment that counts.
    public var dateFrom: Date?
    public var dateTo: Date?
    public var notOlderThan: Age?
    public var olderThan: Age?
    /// Only files have a size to compare; with a size rule, folders are not found.
    public var size: SizeRule?
    public var hidden = TriState.any
    public var directory = TriState.any
    public var symbolicLink = TriState.any
    /// The owner may not write.
    public var readOnly = TriState.any
    /// Somebody may execute it.
    public var executable = TriState.any
    /// A folder shown as a file, such as an application.
    public var package = TriState.any

    public init(
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        notOlderThan: Age? = nil,
        olderThan: Age? = nil,
        size: SizeRule? = nil
    ) {
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.notOlderThan = notOlderThan
        self.olderThan = olderThan
        self.size = size
    }

    public var isEmpty: Bool { self == Self() }

    /// The criteria with the moments worked out once, for testing many files. `nil` when no
    /// criterion is set.
    public func prepared(now: Date, calendar: Calendar = .current) -> PreparedCriteria? {
        isEmpty ? nil : PreparedCriteria(self, now: now, calendar: calendar)
    }
    public var hasAttributes: Bool {
        [hidden, directory, symbolicLink, readOnly, executable, package].contains { $0 != .any }
    }

    /// `now` is the moment the search started, so every file is measured against the same.
    public func matches(_ item: FileItem, now: Date, calendar: Calendar = .current) -> Bool {
        PreparedCriteria(self, now: now, calendar: calendar).matches(item)
    }
}

/// `FileCriteria` with the ages turned into moments, so a search does the calendar
/// arithmetic once, not for every file.
///
/// Immutable; may be used from several threads.
public struct PreparedCriteria {
    private let criteria: FileCriteria
    private let notOlderCutoff: Date?
    private let olderCutoff: Date?

    init(_ criteria: FileCriteria, now: Date, calendar: Calendar) {
        self.criteria = criteria
        notOlderCutoff = criteria.notOlderThan?.cutoff(before: now, calendar: calendar)
        olderCutoff = criteria.olderThan?.cutoff(before: now, calendar: calendar)
    }

    public func matches(_ item: FileItem) -> Bool {
        let c = criteria
        if let dateFrom = c.dateFrom, item.modified < dateFrom {
            return false
        }
        if let dateTo = c.dateTo, item.modified > dateTo {
            return false
        }
        if let notOlderCutoff, item.modified < notOlderCutoff {
            return false
        }
        if let olderCutoff, item.modified >= olderCutoff {
            return false
        }
        if let size = c.size, item.isDirectory || !size.matches(item.size) {
            return false
        }
        return c.hidden.accepts(item.isHidden) && c.directory.accepts(item.isDirectory)
            && c.symbolicLink.accepts(item.isSymlink)
            && c.readOnly.accepts(item.permissions & 0o200 == 0)
            && c.executable.accepts(item.permissions & 0o111 != 0 && !item.isDirectory)
            && c.package.accepts(item.isPackage)
    }
}

/// A piece of information about a file that a rule of the Plugins tab can test: the built-in
/// ones (the `tc` pseudo-plugin of the spec) and every column a plugin registered
/// (spec 09 › Plugins tab).
public struct SearchField: Sendable {
    public let id: String
    public let title: String
    /// May block on the file system; called on the search's threads, several at once.
    public let value: @Sendable (FileItem) -> String

    public static func builtIn(fileSystems: FileSystemRegistry) -> [Self] {
        [
            Self(id: "tc.name", title: "Name") { $0.name },
            Self(id: "tc.ext", title: "Extension") { FileItem.split($0.name).ext },
            Self(id: "tc.fullname", title: "Full name with path") { fileSystems.displayPath($0.url) },
            Self(id: "tc.path", title: "Path") { fileSystems.displayPath($0.url.deletingLastPathComponent()) },
            Self(id: "tc.size", title: "Size in bytes") { $0.isDirectory ? "" : String($0.size) },
            Self(id: "tc.date", title: "Date") { Format.date($0.modified) },
            Self(id: "tc.attr", title: "Permissions") { Format.permissions($0.permissions) }
        ]
    }

    /// The built-in fields followed by the plugins' columns.
    public static func all(fileSystems: FileSystemRegistry, columns: ColumnRegistry?) -> [Self] {
        builtIn(fileSystems: fileSystems)
            + (columns?.all ?? [])
            .map { column in
                Self(id: column.id, title: column.title, value: column.value)
            }
    }
}

/// One row of the Plugins tab: field, operator, value.
public struct FieldRule: Codable, Equatable, Sendable {
    public enum Operator: Int, Codable, CaseIterable, Sendable {
        case contains, notContains, containsCase, notContainsCase, equals, notEquals, equalsCase, notEqualsCase, regex,
            notRegex
        case greater, less, greaterOrEqual, lessOrEqual

        public var title: String {
            [
                "contains", "!contains", "cont.(case)", "!cont.(case)", "=", "!=", "=(case)", "!=(case)", "regex",
                "!regex", ">", "<", ">=", "<="
            ][rawValue]
        }
    }

    public var field: String
    public var comparison: Operator
    public var value: String

    public init(_ field: String, _ comparison: Operator, _ value: String) {
        self.field = field
        self.comparison = comparison
        self.value = value
    }

    /// Whether the rule's operator reads its value as a regular expression.
    public var usesRegex: Bool { comparison == .regex || comparison == .notRegex }

    /// The value as a regular expression; nil when the operator is no regex one or the value is not one.
    func compiledExpression() -> NSRegularExpression? {
        usesRegex ? try? NSRegularExpression(pattern: value, options: .caseInsensitive) : nil
    }

    /// False for a regex rule whose value is no regular expression: it can never be judged.
    public var isUsable: Bool { !usesRegex || compiledExpression() != nil }

    /// Tests a field's text.
    ///
    /// The ordering operators compare as numbers when both sides are numbers (digit grouping is
    /// ignored), otherwise as text without regard to case.
    public func matches(_ text: String) -> Bool {
        matches(text, expression: compiledExpression(), trip: nil, cancelled: { false })
    }

    /// The same with the regular expression compiled once (`compiledExpression()`); a run that
    /// takes the expression too long, or is cancelled, finds no match.
    ///
    /// A value that is no expression never matches `regex` and always matches `!regex`.
    func matches(_ text: String, expression: NSRegularExpression?, trip: RegexTrip?, cancelled: () -> Bool) -> Bool {
        switch comparison {
        case .contains:
            return text.range(of: value, options: .caseInsensitive) != nil

        case .notContains:
            return text.range(of: value, options: .caseInsensitive) == nil

        case .containsCase:
            return text.contains(value)

        case .notContainsCase:
            return !text.contains(value)

        case .equals:
            return text.caseInsensitiveCompare(value) == .orderedSame

        case .notEquals:
            return text.caseInsensitiveCompare(value) != .orderedSame

        case .equalsCase:
            return text == value

        case .notEqualsCase:
            return text != value

        case .regex:
            guard let expression else {
                return false
            }
            return FindRegex.matches(expression, in: text, trip: trip, cancelled: cancelled)

        case .notRegex:
            guard let expression else {
                return true
            }
            return !FindRegex.matches(expression, in: text, trip: trip, cancelled: cancelled)

        case .greater, .less, .greaterOrEqual, .lessOrEqual:
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

    static func number(_ text: String) -> Double? {
        Double(text.filter { $0 != "," && $0 != " " && $0 != "\u{a0}" })
    }
}

/// The rule list of the Plugins tab (spec 09 › Plugins tab).
public struct FieldRules: Codable, Equatable, Sendable {
    /// Switches the whole list on or off without clearing it.
    public var isEnabled: Bool
    /// AND (all rules match) or OR (any rule matches).
    public var matchAll: Bool
    public var rules: [FieldRule]

    public init(isEnabled: Bool = false, matchAll: Bool = true, rules: [FieldRule] = []) {
        self.isEnabled = isEnabled
        self.matchAll = matchAll
        self.rules = rules
    }

    public var isActive: Bool { isEnabled && !rules.isEmpty }

    /// The first rule that cannot be used because its regular expression is none; the search is
    /// not started with such a list.
    public var unusableRule: FieldRule? { isActive ? rules.first { !$0.isUsable } : nil }

    /// A rule whose field no longer exists (its plugin is gone) never matches.
    public func matches(_ item: FileItem, fields: [String: SearchField]) -> Bool {
        prepared().matches(item, fields: fields)
    }

    /// The rules with their regular expressions compiled once, for testing many files from
    /// several threads.
    func prepared(trip: RegexTrip? = nil) -> PreparedFieldRules {
        PreparedFieldRules(self, trip: trip)
    }
}

/// `FieldRules` with the expressions compiled; immutable, safe to use from several threads.
struct PreparedFieldRules {
    private let rules: FieldRules
    private let expressions: [NSRegularExpression?]
    private let trip: RegexTrip?

    init(_ rules: FieldRules, trip: RegexTrip?) {
        self.rules = rules
        self.trip = trip
        expressions = rules.rules.map { $0.compiledExpression() }
    }

    func matches(_ item: FileItem, fields: [String: SearchField], cancelled: () -> Bool = { false }) -> Bool {
        guard rules.isActive else {
            return true
        }
        func holds(_ index: Int) -> Bool {
            let rule = rules.rules[index]
            guard !cancelled() else {
                return false
            }
            return fields[rule.field]
                .map {
                    rule.matches($0.value(item), expression: expressions[index], trip: trip, cancelled: cancelled)
                } ?? false
        }
        // Any rule (the rarer choice), or all of them.
        return !rules.matchAll ? rules.rules.indices.contains(where: holds) : rules.rules.indices.allSatisfy(holds)
    }
}
