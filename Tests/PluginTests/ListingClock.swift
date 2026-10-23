import Foundation

/// The dates the listing tests expect, in UTC, and the "now" they parse with.
internal enum ListingClock {
    /// The Gregorian calendar in UTC, as the parser gets it in the tests.
    internal static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// 15 June 2024, 12:00 UTC: "now" for listings without a year.
    internal static let now = time(2_024, 6, 15, 12, 0)

    /// Midnight UTC at the start of a day.
    internal static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        time(year, month, day, 0, 0)
    }

    /// A minute of a day, UTC (add seconds to the date for a time with seconds).
    ///
    /// Counted by hand rather than with the calendar, so the expected dates do not come from the code the
    /// parser uses: days since 1970 by Howard Hinnant's `days_from_civil`, for years from 1 on.
    internal static func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        // The year starts in March, so the leap day is its last day.
        let marchYear = month <= 2 ? year - 1 : year
        let era = marchYear / 400
        let yearOfEra = marchYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: TimeInterval(((days * 24 + hour) * 60 + minute) * 60))
    }
}
