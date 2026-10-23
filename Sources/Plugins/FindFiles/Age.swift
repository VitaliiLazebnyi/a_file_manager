public import Foundation

/// "Not older than 3 days" (spec 09 › Advanced tab).
public struct Age: Codable, Equatable, Sendable {
    /// The unit of an age, in the order of the menu; stored by its number in saved searches.
    public enum Unit: Int, Codable, CaseIterable, Sendable {
        /// Minutes.
        case minutes = 0
        /// Hours.
        case hours = 1
        /// Days, counted from midnight.
        case days = 2
        /// Weeks of seven days, counted from midnight.
        case weeks = 3
        /// Calendar months, counted from midnight.
        case months = 4
        /// Calendar years, counted from midnight.
        case years = 5

        /// The title in the menu.
        public var title: String { ["minute(s)", "hour(s)", "day(s)", "week(s)", "month(s)", "year(s)"][rawValue] }
    }

    /// The most of any unit that is calculated with: a count typed or loaded beyond this (a
    /// saved search can hold any number) is held to it instead of overflowing.
    public static let largestCount = 1_000_000

    /// How many units.
    public var count: Int
    /// The unit counted.
    public var unit: Unit

    /// `count` units of `unit`.
    public init(_ count: Int, _ unit: Unit) {
        self.count = count
        self.unit = unit
    }

    /// The moment that lies this far before `now`.
    ///
    /// For days and longer units it is midnight of that day, not the current time of day. A count
    /// beyond what the calendar can reach gives the earliest moment there is.
    public func cutoff(before now: Date, calendar: Calendar = .current) -> Date {
        let units = min(max(count, 0), Self.largestCount)
        var step = DateComponents()
        switch unit {
        case .minutes:
            step.minute = -units

        case .hours:
            step.hour = -units

        case .days:
            step.day = -units

        case .weeks:
            step.day = -7 * units

        case .months:
            step.month = -units

        case .years:
            step.year = -units
        }
        guard let moment = calendar.date(byAdding: step, to: now) else {
            return .distantPast
        }
        return unit.rawValue >= Unit.days.rawValue ? calendar.startOfDay(for: moment) : moment
    }
}
