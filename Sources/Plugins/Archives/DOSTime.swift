import Foundation

/// Dates as DOS and ZIP store them: local time, two-second steps, from 1980.
internal enum DOSTime {
    /// The date of a DOS time and date field.
    internal static func date(time: UInt16, date: UInt16) -> Date {
        var components = DateComponents()
        components.year = 1_980 + Int(date >> 9)
        components.month = max(1, Int(date >> 5 & 0xF))
        components.day = max(1, Int(date & 0x1F))
        components.hour = Int(time >> 11)
        components.minute = Int(time >> 5 & 0x3F)
        components.second = Int(time & 0x1F) * 2
        // Every field is in a range the Gregorian calendar takes (a year from 1980 to 2107, a
        // month and a day of at least 1, an hour below 32, minutes and seconds below 64; larger
        // values roll over into the next unit), so a date always comes out.
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// The DOS time and date fields of a date; dates before 1980 (and dates that are not finite) become
    /// 1 January 1980.
    internal static func encode(_ date: Date) -> (time: UInt16, date: UInt16) {
        guard date.timeIntervalSince1970.isFinite else {
            return (0, 0x21)
        }
        let calendar = Calendar(identifier: .gregorian)
        func part(_ component: Calendar.Component) -> UInt16 { UInt16(calendar.component(component, from: date)) }
        let year = calendar.component(.year, from: date)
        guard year >= 1_980 else {
            return (0, 0x21)
        }
        let day = UInt16(min(year - 1_980, 127)) << 9 | part(.month) << 5 | part(.day)
        let time = part(.hour) << 11 | part(.minute) << 5 | part(.second) / 2
        return (time, day)
    }
}
