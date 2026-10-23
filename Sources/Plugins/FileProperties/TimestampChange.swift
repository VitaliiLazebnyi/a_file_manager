import Foundation

/// A new date and time of last change (spec 07 › Change attributes › Date and time).
///
/// The date is written `yyyy-MM-dd` and the time `HH:mm:ss`, with any separators. A part written in
/// letters (`yyyy-05-dd`, `hh:10:ss`), and an empty field, keeps what the file has.
internal struct TimestampChange: Equatable {
    /// A field that is neither empty nor a date or time in the form above.
    private struct Unreadable: Error {}

    /// Gives every item the moment the command runs.
    internal static let current = Self(parts: Array(repeating: nil, count: 6), usesCurrentTime: true)

    /// Year, month, day, hour, minute, second; nil keeps that part of the file's own date.
    internal var parts: [Int?]
    /// The moment the command ran, for every item alike.
    internal var usesCurrentTime = false

    /// Whether every part keeps what the file has, so that no date is written at all.
    internal var changesNothing: Bool { !usesCurrentTime && parts.allSatisfy { $0 == nil } }

    /// Nil when a field is neither empty nor a date or time in the form above.
    internal init?(date: String, time: String) {
        guard let day = try? Self.fields(date, count: 3...3, limits: [1...9_999, 1...12, 1...31]),
            var clock = try? Self.fields(time, count: 2...4, limits: [0...23, 0...59, 0...59, 0...999])
        else { return nil }
        // Seconds that are left out become 0; fractions of a second are not kept.
        if clock.count == 2 { clock.append(0) }
        parts = day + clock.prefix(3)
    }

    private init(parts: [Int?], usesCurrentTime: Bool) {
        self.parts = parts
        self.usesCurrentTime = usesCurrentTime
    }

    /// The numbers of one field, nil for a part written in letters; three nils for an empty field.
    ///
    /// Throws when the field has too few or too many parts, or a number outside its limits.
    private static func fields(
        _ text: String,
        count: ClosedRange<Int>,
        limits: [ClosedRange<Int>]
    ) throws(Unreadable) -> [Int?] {
        let tokens = text.split { !$0.isLetter && !$0.isNumber }
        if tokens.isEmpty {
            return Array(repeating: nil, count: 3)
        }
        guard count.contains(tokens.count) else {
            throw Unreadable()
        }
        var fields: [Int?] = []
        for (token, limit) in zip(tokens, limits) {
            if token.allSatisfy(\.isLetter) {
                fields.append(nil)
            } else if let number = Int(token), limit.contains(number) {
                fields.append(number)
            } else {
                throw Unreadable()
            }
        }
        return fields
    }

    /// A date as the fields of the dialog show it, in `calendar`.
    internal static func fieldTexts(for date: Date, calendar: Calendar) -> (date: String, time: String) {
        func part(_ component: Calendar.Component) -> Int { calendar.component(component, from: date) }
        return (
            String(format: "%04d-%02d-%02d", part(.year), part(.month), part(.day)),
            String(format: "%02d:%02d:%02d", part(.hour), part(.minute), part(.second))
        )
    }

    /// The new date of an item last changed at `original`, with the parts read in `calendar`; nil
    /// when the parts do not make a date (the 31st of a month with 30 days).
    internal func applied(to original: Date, now: Date, calendar: Calendar) -> Date? {
        if usesCurrentTime {
            return now
        }
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: original
        )
        if let year = parts[0] { components.year = year }
        if let month = parts[1] { components.month = month }
        if let day = parts[2] { components.day = day }
        if let hour = parts[3] { components.hour = hour }
        if let minute = parts[4] { components.minute = minute }
        if let second = parts[5] {
            components.second = second
            components.nanosecond = 0
        }
        components.calendar = calendar
        guard components.isValidDate else {
            return nil
        }
        return calendar.date(from: components)
    }
}
